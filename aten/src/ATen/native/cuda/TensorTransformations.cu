#include "ATen/native/TensorTransformations.h"

#include "ATen/cuda/detail/IndexUtils.cuh"
#include "ATen/NativeFunctions.h"
#include "ATen/cuda/CUDAContext.h"

#include <cstddef>
#include <vector>

namespace at {
namespace native {

#define AT_APPLY_THREADS_PER_BLOCK 32 * 16
#define AT_APPLY_BLOCKS_PER_SM 4

template <typename scalar_t, typename IndexType>
#if __CUDA_ARCH__ >= 350
__launch_bounds__(AT_APPLY_THREADS_PER_BLOCK, AT_APPLY_BLOCKS_PER_SM)
#endif
__global__ void
kernel_pointwise_flip_apply2(const cuda::detail::TensorInfo<scalar_t, IndexType> in_tensor_info,
                          cuda::detail::TensorInfo<scalar_t, IndexType> out_tensor_info,
                          IndexType N,
                          int flip_dim,
                          IndexType total_dims) {
  for (IndexType linear_index = blockIdx.x * blockDim.x + threadIdx.x; linear_index < N; linear_index += gridDim.x * blockDim.x) {
    IndexType dst_offset = 0;
    if (flip_dim == 0) {
      // flip 1st dim
      dst_offset = (in_tensor_info.sizes[0] - 1 - linear_index / in_tensor_info.strides[0]) * in_tensor_info.strides[0] + linear_index % in_tensor_info.strides[0];
    }
    else {
      // flip last dim
      IndexType i = total_dims - 1;
      dst_offset = linear_index / in_tensor_info.strides[0] * in_tensor_info.strides[0] + (in_tensor_info.sizes[i] - 1 - linear_index % in_tensor_info.strides[0]);
    }
    out_tensor_info.data[dst_offset] = in_tensor_info.data[linear_index];
  }
}

template <typename scalar_t>
__global__
void flip_cuda_kernel(scalar_t* in_tensor, scalar_t* out_tensor, int64_t N, int64_t* flip_dims, int64_t flip_dims_size,
                      int64_t* strides, int64_t* strides_contiguous, int64_t* shape, int64_t total_dims) {

  int64_t linear_index = blockIdx.x * blockDim.x + threadIdx.x;
  if (linear_index >= N) {
    return;
  }

  int64_t cur_indices = linear_index, rem = 0, dst_offset = 0;
  for (int64_t i = 0; i < total_dims; i++) {
    int64_t temp = cur_indices;
    cur_indices = cur_indices / strides_contiguous[i];
    rem = temp - cur_indices * strides_contiguous[i];
    // flip the indices if it is in flip_dims
    for (int64_t j = 0; j < flip_dims_size; j++) {
      if (i == flip_dims[j]) {
        cur_indices = shape[i] - 1 - cur_indices;
      }
    }
    dst_offset += cur_indices * strides[i];
    cur_indices = rem;
  }
  out_tensor[linear_index] = in_tensor[dst_offset];
}

// Flip tensor given a list of dims
Tensor flip_cuda(const Tensor& self, IntList dims) {
  auto in_tensor = self;
  const int64_t flip_dims_size = dims.size(), total_dims = in_tensor.dim(), N = in_tensor.numel();
  check_errors(total_dims, flip_dims_size, dims);

  int64_t block_size = 512;
  dim3 dim_block(block_size);
  dim3 dim_grid((N + block_size - 1) / block_size);

  // use kernel_pointwise_flip_apply2 only when to-flip dim is the 1st or last dim, where collapseDims can reduce the amount of work
  if (flip_dims_size == 1 && in_tensor.is_contiguous() && (dims[0] == 0 || dims[0] == total_dims - 1)) {
    auto out_tensor = at::empty_like(self);
    AT_DISPATCH_ALL_TYPES_AND_HALF(in_tensor.type(), "flip_cuda", [&] {
      auto in_tensor_info = cuda::detail::getTensorInfo<scalar_t, int64_t>(in_tensor);
      auto out_tensor_info = cuda::detail::getTensorInfo<scalar_t, int64_t>(out_tensor);
      int flip_dim = in_tensor_info.collapseDims(dims[0]);
      out_tensor_info.collapseDims(dims[0]);
      kernel_pointwise_flip_apply2<scalar_t, int64_t>
        <<<dim_grid, dim_block, 0, at::cuda::getCurrentCUDAStream()>>>(
          in_tensor_info, out_tensor_info, N, flip_dim, total_dims);
    });
    return out_tensor;
  }

  auto flip_dims = std::vector<int64_t>(dims);
  auto flip_dims_t = at::CPU(kLong).tensorFromBlob(flip_dims.data(), {static_cast<int64_t>(flip_dims.size())});

  auto shape = std::vector<int64_t>(in_tensor.sizes());
  auto shape_t = at::CPU(kLong).tensorFromBlob(shape.data(), {static_cast<int64_t>(shape.size())});

  auto strides = std::vector<int64_t>(in_tensor.strides());
  auto strides_t = at::CPU(kLong).tensorFromBlob(strides.data(), {static_cast<int64_t>(strides.size())});

  auto out_tensor = at::empty_like(in_tensor);

  // stride_contiguous is the stride of non-contiguous tensor after calling contiguous(),
  // it is used to compute indices for each element in non-contiguous tensor
  Tensor stride_contiguous = at::zeros({total_dims}, kLong);
  int64_t* stride_contiguous_d = stride_contiguous.data<int64_t>();
  for (int64_t i = total_dims - 1; i >= 0; i--) {
    if (i == total_dims - 1) {
      stride_contiguous_d[i] = 1;
    } else {
      stride_contiguous_d[i] = std::max<int64_t>(shape[i+1], 1) * stride_contiguous_d[i + 1];
    }
  }

  AT_DISPATCH_ALL_TYPES_AND_HALF(in_tensor.type(), "flip_cuda", [&] {
    flip_cuda_kernel<<<dim_grid, dim_block, 0, at::cuda::getCurrentCUDAStream()>>>(
      in_tensor.data<scalar_t>(), out_tensor.data<scalar_t>(), N, flip_dims_t.toType(CUDA(kLong)).data<int64_t>(), flip_dims_size,
      strides_t.toType(CUDA(kLong)).data<int64_t>(), stride_contiguous.toType(CUDA(kLong)).data<int64_t>(), shape_t.toType(CUDA(kLong)).data<int64_t>(), total_dims);
  });

  return out_tensor;
}

}} // namespace at::native
