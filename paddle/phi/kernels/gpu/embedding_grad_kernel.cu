// Copyright (c) 2022 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "paddle/phi/kernels/embedding_grad_kernel.h"

#include "gflags/gflags.h"
#include "glog/logging.h"
#include "paddle/phi/backends/gpu/gpu_context.h"
#include "paddle/phi/backends/gpu/gpu_primitives.h"
#include "paddle/phi/common/amp_type_traits.h"
#include "paddle/phi/common/data_type.h"
#include "paddle/phi/common/memory_utils.h"
#include "paddle/phi/core/kernel_registry.h"
#include "paddle/phi/core/mixed_vector.h"
#include "paddle/phi/kernels/funcs/eigen/common.h"
#include "paddle/phi/kernels/funcs/embedding_util.h"

DECLARE_bool(embedding_deterministic);

namespace phi {

#ifdef PADDLE_WITH_HIP
#define WARP_SIZE 64
#define BLOCKDIMY 16
#else
#define WARP_SIZE 32
#define BLOCKDIMY 32
#endif

#define MASK 0xffffffff

template <typename InT, typename OutT>
__global__ void InputTypeConvert(const InT* in_ids,
                                 const int64_t K,
                                 OutT* out_ids) {
  for (int i = 0; i < K; i++) {
    out_ids[i] = static_cast<OutT>(in_ids[i]);
  }
}

template <typename T, typename IdT>
__global__ void EmbeddingGrad(T* table,
                              const T* output,
                              const IdT* ids,
                              const int64_t N,
                              const int64_t K,
                              const int64_t D) {
  int idx = threadIdx.x;
  int idy = blockIdx.x + threadIdx.y * gridDim.x;

  while (idy < K) {
    auto id = static_cast<int64_t>(ids[idy]);
    const T* out = output + idy * D;
    T* tab = table + id * D;
#ifdef PADDLE_WITH_CUDA
    phi::VectorizedAtomicAddPerBlock(D, idx, blockDim.x, out, tab);
#else
    for (int i = idx; i < D; i += blockDim.x) {
      phi::CudaAtomicAdd(&tab[i], out[i]);
    }
#endif
    idy += blockDim.y * gridDim.x;
  }
}

template <typename T, typename IdT>
__global__ void EmbeddingGradDeterministic(
    T* table, const T* output, const IdT* ids, const IdT K, const IdT D) {
  using MT = typename dtype::MPTypeTrait<T>::Type;
  extern __shared__ char buf[];
  MT* smem = reinterpret_cast<MT*>(buf);
  MT* my_s = smem + WARP_SIZE * threadIdx.y;
  IdT* indices_batch =
      reinterpret_cast<IdT*>(buf + sizeof(MT) * WARP_SIZE * BLOCKDIMY);

  const int stride = static_cast<int>(D);

  const int feature = threadIdx.x + blockIdx.x * WARP_SIZE;

  // To ensure determinism. If any other warps pulled grad data targeting
  // dst_row, we elect the first warp in each matching group as the leader.
  // Each leader warp serializes the accumulates targeting dst_row in shared
  // memory, then adding the accumulated buffer to dst_row in table.
  for (int batch_start = 0; batch_start < K;
       batch_start += WARP_SIZE * BLOCKDIMY) {
    int tid = threadIdx.x + threadIdx.y * WARP_SIZE;
    if (batch_start + tid < K)
      indices_batch[tid] = static_cast<IdT>(ids[batch_start + tid]);

    int batch_end =
        min(static_cast<IdT>(batch_start + WARP_SIZE * BLOCKDIMY), K);

    // Loop over the batch of <= 1024 loaded indices in chunks of BLOCKDIMY
    for (int chunk_start = batch_start; chunk_start < batch_end;
         chunk_start += BLOCKDIMY) {
      // This sync makes sure that indices_batch is ready and match-group
      // leaders are done with their accumulates before other warps start
      // loading again.
      __syncthreads();

      int n_this_chunk = min(batch_end - chunk_start, BLOCKDIMY);

      IdT src_row = static_cast<IdT>(chunk_start + threadIdx.y);
      IdT dst_row = indices_batch[src_row - batch_start];
      if (src_row < K && feature < stride)
        my_s[threadIdx.x] = static_cast<MT>(output[src_row * D + feature]);

      __syncthreads();

      if (src_row < K) {
        int match_found_this_thread = 0;
        if (threadIdx.x < n_this_chunk) {
          match_found_this_thread =
              (dst_row ==
               indices_batch[chunk_start - batch_start + threadIdx.x]);
        }
#ifdef PADDLE_WITH_HIP
        unsigned long long int matchmask =      // NOLINT
            __ballot(match_found_this_thread);  // NOLINT
        int first_remaining_peer = __ffsll(matchmask) - 1;
#else
        // If and only if match_found_this_thread of the Nth thread is non-zero,
        // set the Nth bit of matchmask to 1.
        unsigned int matchmask = __ballot_sync(MASK, match_found_this_thread);
        // Find the position of the first bit set to 1 in matchmask.
        int first_remaining_peer = __ffs(matchmask) - 1;
#endif

        // select lowest-indexed warp as the leader
        if (threadIdx.y == first_remaining_peer) {
          // Set the first bit 1 in matchmask to 0.
          matchmask ^= (1 << first_remaining_peer);
          while (matchmask) {
#ifdef PADDLE_WITH_HIP
            first_remaining_peer = __ffsll(matchmask) - 1;
#else
            first_remaining_peer = __ffs(matchmask) - 1;
#endif
            my_s[threadIdx.x] +=
                smem[threadIdx.x + WARP_SIZE * first_remaining_peer];
            matchmask ^= (1 << first_remaining_peer);
          }
          if (feature < stride)
            table[dst_row * D + feature] += static_cast<T>(my_s[threadIdx.x]);
        }
      }
    }
  }
}

template <typename T, typename Context>
struct EmbeddingGradCUDAFunctor {
  EmbeddingGradCUDAFunctor(const Context& dev_ctx,
                           const DenseTensor& input,
                           const DenseTensor& weight,
                           const DenseTensor& out_grad,
                           int64_t padding_idx,
                           DenseTensor* weight_grad)
      : dev_ctx_(dev_ctx),
        input_(input),
        weight_(weight),
        out_grad_(out_grad),
        padding_idx_(padding_idx),
        weight_grad_(weight_grad) {}

  template <typename IdT>
  void apply() {
    // Since paddings are not trainable and fixed in forward, the gradient of
    // paddings makes no sense and we don't deal with it in backward.
    {
      auto d_output_t = out_grad_;
      auto d_table_t = weight_grad_;

      int N = weight_grad_->dims()[0];
      int D = weight_grad_->dims()[1];
      int K = input_.numel();

      const T* d_output = d_output_t.template data<T>();
      const auto* ids = input_.template data<IdT>();
      T* d_table = dev_ctx_.template Alloc<T>(d_table_t);

#ifdef PADDLE_WITH_HIP
      PADDLE_ENFORCE_GPU_SUCCESS(
          hipMemsetAsync(d_table, 0, N * D * sizeof(T), dev_ctx_.stream()));
#else
      PADDLE_ENFORCE_GPU_SUCCESS(
          cudaMemsetAsync(d_table, 0, N * D * sizeof(T), dev_ctx_.stream()));
#endif

      if (FLAGS_embedding_deterministic) {
        dim3 threads(WARP_SIZE, BLOCKDIMY);
        dim3 grids(static_cast<int>((D + WARP_SIZE - 1) / WARP_SIZE));
        using MT = typename dtype::MPTypeTrait<T>::Type;
        EmbeddingGradDeterministic<T, IdT>
            <<<grids,
               threads,
               sizeof(MT) * WARP_SIZE * BLOCKDIMY +
                   sizeof(IdT) * WARP_SIZE * BLOCKDIMY,
               dev_ctx_.stream()>>>(d_table, d_output, ids, K, D);
      } else {
        const int gridx = 2 * dev_ctx_.GetSMCount();
        dim3 threads(128, 8);
        dim3 grids(gridx, 1);
        EmbeddingGrad<T, IdT><<<grids, threads, 0, dev_ctx_.stream()>>>(
            d_table, d_output, ids, N, K, D);
      }
    }
  }

 private:
  const phi::GPUContext& dev_ctx_;
  const DenseTensor& input_;
  const DenseTensor& weight_;
  const DenseTensor& out_grad_;
  int64_t padding_idx_;
  DenseTensor* weight_grad_;
};

template <typename T, typename Context>
void EmbeddingGradKernel(const Context& ctx,
                         const DenseTensor& input,
                         const DenseTensor& weight,
                         const DenseTensor& out_grad,
                         int64_t padding_idx,
                         DenseTensor* weight_grad) {
  EmbeddingGradCUDAFunctor<T, Context> functor(
      ctx, input, weight, out_grad, padding_idx, weight_grad);

  if (input.dtype() == phi::DataType::INT32) {
    functor.template apply<int>();
  } else if (input.dtype() == phi::DataType::INT64) {
    functor.template apply<int64_t>();
  } else if (input.dtype() == phi::DataType::INT16) {
    functor.template apply<int16_t>();
  } else {
    PADDLE_THROW(phi::errors::Unimplemented(
        "emebdding input only support int16, int32 and int64"));
  }
}

template <typename T, typename Context>
struct EmbeddingSparseGradCUDAFunctor {
  EmbeddingSparseGradCUDAFunctor(const Context& dev_ctx,
                                 const DenseTensor& input,
                                 const DenseTensor& weight,
                                 const DenseTensor& out_grad,
                                 int64_t padding_idx,
                                 SelectedRows* weight_grad)
      : dev_ctx_(dev_ctx),
        input_(input),
        weight_(weight),
        out_grad_(out_grad),
        padding_idx_(padding_idx),
        weight_grad_(weight_grad) {}

  template <typename IdT>
  void apply() {
    // Since paddings are not trainable and fixed in forward, the gradient of
    // paddings makes no sense and we don't deal with it in backward.

    const auto* ids_data = input_.template data<IdT>();
    auto* d_table = weight_grad_;
    auto* table = &weight_;
    auto* d_output = &out_grad_;
    int64_t ids_num = input_.numel();
    dim3 threads(128, 8);
    dim3 grids(8, 1);
    auto stream = dev_ctx_.stream();
    phi::Vector<int64_t> new_rows;
    new_rows.resize(ids_num);
    auto gpu_place = dev_ctx_.GetPlace();

    phi::MixVector<int64_t> mixv_new_rows(&new_rows);
    if (!std::is_same<IdT, int64_t>::value) {
      InputTypeConvert<<<grids, threads, 0, stream>>>(
          ids_data, ids_num, mixv_new_rows.MutableData(gpu_place));
    } else {
      memory_utils::Copy(gpu_place,
                         mixv_new_rows.CUDAMutableData(gpu_place),
                         gpu_place,
                         ids_data,
                         ids_num * sizeof(int64_t),
                         stream);
    }

    mixv_new_rows.CopyToCPU();
    d_table->set_rows(new_rows);

    auto* d_table_value = d_table->mutable_value();
    d_table_value->Resize({ids_num, table->dims()[1]});
    dev_ctx_.template Alloc<T>(d_table_value);

    auto* d_table_data = d_table_value->template data<T>();
    auto* d_output_data = d_output->template data<T>();
    auto d_output_dims = d_output->dims();
    auto d_output_dims_2d =
        phi::flatten_to_2d(d_output_dims, d_output_dims.size() - 1);
    PADDLE_ENFORCE_EQ(d_table_value->dims(),
                      d_output_dims_2d,
                      phi::errors::InvalidArgument(
                          "ShapeError: The shape of lookup_table@Grad and "
                          "output@Grad should be same. "
                          "But received lookup_table@Grad's shape = [%s], "
                          "output@Grad's shape = [%s].",
                          d_table_value->dims(),
                          d_output_dims_2d));
    memory_utils::Copy(gpu_place,
                       d_table_data,
                       gpu_place,
                       d_output_data,
                       d_output->numel() * sizeof(T),
                       stream);
  }

 private:
  const phi::GPUContext& dev_ctx_;
  const DenseTensor& input_;
  const DenseTensor& weight_;
  const DenseTensor& out_grad_;
  int64_t padding_idx_;
  SelectedRows* weight_grad_;
};

template <typename T, typename Context>
void EmbeddingSparseGradKernel(const Context& ctx,
                               const DenseTensor& input,
                               const DenseTensor& weight,
                               const DenseTensor& out_grad,
                               int64_t padding_idx,
                               SelectedRows* weight_grad) {
  EmbeddingSparseGradCUDAFunctor<T, Context> functor(
      ctx, input, weight, out_grad, padding_idx, weight_grad);

  if (input.dtype() == phi::DataType::INT32) {
    functor.template apply<int>();
  } else if (input.dtype() == phi::DataType::INT64) {
    functor.template apply<int64_t>();
  } else if (input.dtype() == phi::DataType::INT16) {
    functor.template apply<int16_t>();
    PADDLE_THROW(phi::errors::Unimplemented(
        "emebdding input only support int16, int32 and int64"));
  }
}

}  // namespace phi

PD_REGISTER_KERNEL(embedding_grad,
                   GPU,
                   ALL_LAYOUT,
                   phi::EmbeddingGradKernel,
                   float,
                   double,
                   phi::dtype::float16,
                   phi::dtype::bfloat16) {}

PD_REGISTER_KERNEL(embedding_sparse_grad,
                   GPU,
                   ALL_LAYOUT,
                   phi::EmbeddingSparseGradKernel,
                   float,
                   double,
                   phi::dtype::float16,
                   phi::dtype::bfloat16) {}
