///|
// Genuine Warp scalar fallback primitives and source-order small block code.
// CUDA source only. This function is never called during static verification.
fn helpers() -> String {
  let source =
    #|template<class T> __device__ bool mr_finite(T value) { return wp::isfinite(value); }
    #|__device__ void mr_fail(wp::array_t<wp::int32> failure,int w) { wp::atomic_or(failure,w,1); }
    #|template<class T> __device__ bool mr_inverse(T value,T& result,wp::array_t<wp::int32> failure,int w,bool positive) {
    #|  if(!mr_finite(value) || value==T(0) || (positive && value<=T(0))) {mr_fail(failure,w);result=T(0);return false;}
    #|  result=T(1)/value;
    #|  if(!mr_finite(result)) {mr_fail(failure,w);return false;}
    #|  return true;
    #|}
    #|template<class T,bool F,bool S> __device__ void mr_small(int n,int start,int fa,int ma,int w,
    #|  wp::array_t<T> matrix,wp::array_t<T> factor,wp::array_t<T> diagonal,
    #|  wp::array_t<T> rhs,wp::array_t<T> solution,wp::array_t<wp::int32> failure) {
    #|  if(threadIdx.x!=0) return;
    #|  if(fa==-2) {
    #|    for(int i=0;i<n;++i) {
    #|      T inverse;
    #|      if constexpr(F) {if(!mr_inverse(wp::index(matrix,w,ma+i),inverse,failure,w,true)) return;wp::index(diagonal,w,start+i)=inverse;}
    #|      else {inverse=wp::index(diagonal,w,start+i);if(!mr_finite(inverse)||inverse<=T(0)){mr_fail(failure,w);return;}}
    #|      if constexpr(S) {T value=inverse*wp::index(rhs,w,start+i);if(!mr_finite(value))mr_fail(failure,w);wp::index(solution,w,start+i)=value;}
    #|    }
    #|    return;
    #|  }
    #|  if constexpr(F) {
    #|    for(int i=0;i<n;++i) {
    #|      T value=wp::index(matrix,w,ma+i*(i+1)/2+i);
    #|      T rv=T(0);if constexpr(S) rv=wp::index(rhs,w,start+i);
    #|      for(int k=0;k<i;++k) {T f=wp::index(factor,w,fa+k*n+i);value-=f*f;if constexpr(S) rv-=f*wp::index(solution,w,start+k);}
    #|      if(!mr_finite(value)||value<=T(0)){mr_fail(failure,w);return;}
    #|      T d=wp::sqrt(value),inverse;if(!mr_inverse(d,inverse,failure,w,true))return;
    #|      wp::index(factor,w,fa+i*n+i)=d;
    #|      if constexpr(S) {T v=rv*inverse;if(!mr_finite(v))mr_fail(failure,w);wp::index(solution,w,start+i)=v;}
    #|      for(int j=i+1;j<n;++j){T v=wp::index(matrix,w,ma+j*(j+1)/2+i);for(int k=0;k<i;++k)v-=wp::index(factor,w,fa+k*n+i)*wp::index(factor,w,fa+k*n+j);v*=inverse;if(!mr_finite(v))mr_fail(failure,w);wp::index(factor,w,fa+i*n+j)=v;}
    #|    }
    #|  }
    #|  if constexpr(S) {
    #|    if constexpr(!F) {
    #|      for(int i=0;i<n;++i){T v=wp::index(rhs,w,start+i);for(int k=0;k<i;++k)v-=wp::index(factor,w,fa+k*n+i)*wp::index(solution,w,start+k);T d=wp::index(factor,w,fa+i*n+i),inverse;if(!mr_inverse(d,inverse,failure,w,true))return;v/=d;if(!mr_finite(v))mr_fail(failure,w);wp::index(solution,w,start+i)=v;}
    #|    }
    #|    for(int reverse=0;reverse<n;++reverse){int i=n-1-reverse;T v=wp::index(solution,w,start+i);for(int k=i+1;k<n;++k)v-=wp::index(factor,w,fa+i*n+k)*wp::index(solution,w,start+k);T d=wp::index(factor,w,fa+i*n+i),inverse;if(!mr_inverse(d,inverse,failure,w,true))return;v/=d;if(!mr_finite(v))mr_fail(failure,w);wp::index(solution,w,start+i)=v;}
    #|  }
    #|}
    #|template<class T,int N,bool F,bool S> __device__ void mr_gather(int start,int fa,int go,int w,T* a,T* b,
    #|  wp::array_t<wp::int32> gather_indices,wp::array_t<T> matrix,wp::array_t<T> factor,
    #|  wp::array_t<T> rhs,wp::array_t<T> solution,wp::array_t<wp::int32> failure) {
    #|  int lane=int(threadIdx.x);
    #|  for(int slot=lane;slot<N*N;slot+=MR_THREADS){T v;if constexpr(F){int index=wp::index(gather_indices,go+slot);v=index==MR_NC?T(0):wp::index(matrix,w,index);}else v=wp::index(factor,w,fa+slot);a[slot]=v;if(slot/N<=slot%N && !mr_finite(v))mr_fail(failure,w);}
    #|  if constexpr(S){for(int i=lane;i<N;i+=MR_THREADS){b[i]=wp::index(rhs,w,start+i);if(!mr_finite(b[i]))mr_fail(failure,w);}}
    #|  __syncthreads();
    #|  using ALayout=wp::tile_layout_strided_t<wp::tile_shape_t<N,N>>;
    #|  wp::tile_shared_t<T,ALayout,false> A(a,nullptr,true);
    #|  if constexpr(F) wp::tile_cholesky_inplace<true>(0,A);
    #|  __syncthreads();
    #|  for(int slot=lane;slot<N*N;slot+=MR_THREADS){if(slot/N<=slot%N && (!mr_finite(a[slot]) || (slot/N==slot%N && a[slot]<=T(0))))mr_fail(failure,w);if constexpr(F)wp::index(factor,w,fa+slot)=a[slot];}
    #|  __syncthreads();
    #|  if constexpr(S){
    #|    using BLayout=wp::tile_layout_strided_t<wp::tile_shape_t<N>>;
    #|    wp::tile_shared_t<T,BLayout,false> B(b,nullptr,true);
    #|    wp::tile_cholesky_solve_inplace<true>(0,A,B);
    #|    __syncthreads();
    #|    for(int i=lane;i<N;i+=MR_THREADS){if(!mr_finite(b[i]))mr_fail(failure,w);wp::index(solution,w,start+i)=b[i];}
    #|  }
    #|  __syncthreads();
    #|}
    #|template<class T,bool F,bool S> __device__ void mr_sparse(int w,wp::array_t<wp::int32> row_nnz,
    #|  wp::array_t<wp::int32> row_adr,wp::array_t<wp::int32> factor_adr,wp::array_t<wp::int32> updates,
    #|  wp::array_t<wp::int32> level_offsets,wp::array_t<T> matrix,wp::array_t<T> factor,
    #|  wp::array_t<T> diagonal,wp::array_t<T> rhs,wp::array_t<T> solution,wp::array_t<wp::int32> failure) {
    #|  int lane=int(threadIdx.x);
    #|  if constexpr(F){
    #|    // Exact whole-CSR copy, including compact/dense tree rows.
    #|    for(int slot=lane;slot<MR_NC;slot+=MR_THREADS){T value=wp::index(matrix,w,slot);if(!mr_finite(value))mr_fail(failure,w);wp::index(factor,w,MR_PREFIX+slot)=value;}
    #|    __syncthreads();
    #|    for(int reverse=0;reverse<MR_LEVELS;++reverse){int level=MR_LEVELS-1-reverse;
    #|      int first=wp::index(level_offsets,level),end=wp::index(level_offsets,level+1);
    #|      for(int u=first+lane;u<end;u+=MR_THREADS){
    #|        int i=wp::index(updates,u,0),k=wp::index(updates,u,1),ki=wp::index(updates,u,2);
    #|        int ai=wp::index(row_adr,i),ak=wp::index(row_adr,k),dk=ak+wp::index(row_nnz,k)-1;
    #|        T denominator=wp::index(factor,w,MR_PREFIX+dk),inverse,tmp=T(0);if(mr_inverse(denominator,inverse,failure,w,true))tmp=wp::index(factor,w,MR_PREFIX+ki)/denominator;
    #|        if(!mr_finite(tmp))mr_fail(failure,w);
    #|        for(int j=0;j<wp::index(row_nnz,i);++j){T value=wp::index(factor,w,MR_PREFIX+ak+j)*tmp;if(!mr_finite(value))mr_fail(failure,w);wp::atomic_sub(factor,w,MR_PREFIX+ai+j,value);}
    #|        wp::index(factor,w,MR_PREFIX+ki)=tmp;
    #|      }
    #|      __syncthreads();
    #|    }
    #|    // Upstream ALL-nv overwrite is intentional whenever a sparse tail exists.
    #|    for(int i=lane;i<MR_NV;i+=MR_THREADS){int diag=wp::index(row_adr,i)+wp::index(row_nnz,i)-1;T inverse;mr_inverse(wp::index(factor,w,MR_PREFIX+diag),inverse,failure,w,true);wp::index(diagonal,w,i)=inverse;}
    #|    for(int slot=lane;slot<MR_NC;slot+=MR_THREADS)if(!mr_finite(wp::index(factor,w,MR_PREFIX+slot)))mr_fail(failure,w);
    #|    __syncthreads();
    #|  }
    #|  if constexpr(S){
    #|    for(int i=lane;i<MR_NV;i+=MR_THREADS)if(wp::index(factor_adr,i)==-1){T value=wp::index(rhs,w,i);if(!mr_finite(value))mr_fail(failure,w);wp::index(solution,w,i)=value;}
    #|    __syncthreads();
    #|    for(int reverse=0;reverse<MR_LEVELS;++reverse){int level=MR_LEVELS-1-reverse;int first=wp::index(level_offsets,level),end=wp::index(level_offsets,level+1);
    #|      for(int u=first+lane;u<end;u+=MR_THREADS){int i=wp::index(updates,u,0),k=wp::index(updates,u,1),ki=wp::index(updates,u,2);wp::atomic_sub(solution,w,i,wp::index(factor,w,MR_PREFIX+ki)*wp::index(solution,w,k));}
    #|      __syncthreads();
    #|    }
    #|    for(int i=lane;i<MR_NV;i+=MR_THREADS)if(wp::index(factor_adr,i)==-1){T inverse=wp::index(diagonal,w,i);if(!mr_finite(inverse)||inverse<=T(0))mr_fail(failure,w);wp::index(solution,w,i)*=inverse;}
    #|    __syncthreads();
    #|    for(int level=0;level<MR_LEVELS;++level){int first=wp::index(level_offsets,level),end=wp::index(level_offsets,level+1);
    #|      for(int u=first+lane;u<end;u+=MR_THREADS){int i=wp::index(updates,u,0),k=wp::index(updates,u,1),ki=wp::index(updates,u,2);wp::atomic_sub(solution,w,k,wp::index(factor,w,MR_PREFIX+ki)*wp::index(solution,w,i));}
    #|      __syncthreads();
    #|    }
    #|    for(int i=lane;i<MR_NV;i+=MR_THREADS)if(wp::index(factor_adr,i)==-1 && !mr_finite(wp::index(solution,w,i)))mr_fail(failure,w);
    #|    __syncthreads();
    #|  }
    #|}
  source
}
