///|
fn row_has(layout : LuLayout, row : Int32, column : Int32) -> Bool {
  let mut lo = layout.d_rowadr[row]
  let mut hi = lo + layout.d_rownnz[row]
  while lo < hi {
    let middle = lo + (hi - lo) / 2
    if layout.d_colind[middle] < column {
      lo = middle + 1
    } else {
      hi = middle
    }
  }
  lo < layout.d_rowadr[row] + layout.d_rownnz[row] &&
  layout.d_colind[lo] == column
}

///|
fn lu_metadata(request : LuRequest) -> Array[Metadata] raise SolverError {
  let layout = request.layout
  let nv = layout.d_rownnz.length()
  dimensions(
    request.dtype,
    request.nworld,
    request.block_dim,
    request.architecture,
    nv,
    layout.d_colind.length(),
  )
  guard layout.d_rowadr.length() == nv && layout.d_diag.length() == nv else {
    raise Invalid("D-CSR row/diagonal cardinality mismatch")
  }
  let predecessors : Array[Array[Int32]] = Array::makei(nv, _ => [])
  let mut cursor = 0
  for row in 0..<nv {
    guard layout.d_rowadr[row] == cursor &&
      layout.d_rownnz[row] > 0 &&
      layout.d_rownnz[row] <= nv &&
      cursor <= layout.d_colind.length() - layout.d_rownnz[row] &&
      layout.d_diag[row] >= 0 &&
      layout.d_diag[row] < layout.d_rownnz[row] else {
      raise Invalid(
        "D-CSR rows must be contiguous, nonempty and contain an explicit relative diagonal",
      )
    }
    let mut previous = -1
    for slot in cursor..<(cursor + layout.d_rownnz[row]) {
      let col = layout.d_colind[slot]
      guard col > previous && col < nv else {
        raise Invalid("D-CSR columns must be strictly sorted inside the model")
      }
      if col > row {
        predecessors[col].push(row)
      }
      previous = col
    }
    guard layout.d_colind[cursor + layout.d_diag[row]] == row else {
      raise Invalid(
        "D_diag must address the actual row diagonal, not an absolute pointer",
      )
    }
    cursor += layout.d_rownnz[row]
  }
  guard cursor == layout.d_colind.length() else {
    raise Invalid("D-CSR has unused or truncated storage")
  }
  // Prove that the pinned no-fill reverse elimination does not discard a
  // potentially nonzero update. This is symbolic metadata validation only.
  for pivot_row in 0..<nv {
    for target in predecessors[pivot_row] {
      for
        slot in layout.d_rowadr[pivot_row]..<(layout.d_rowadr[pivot_row] +
        layout.d_diag[pivot_row]) {
        guard row_has(layout, target, layout.d_colind[slot]) else {
          raise Invalid(
            "D-CSR is not closed under the source reverse sparse LU elimination; missing fill is not silently dropped",
          )
        }
      }
    }
  }
  [
    integers("d_rownnz", [nv], layout.d_rownnz),
    integers("d_rowadr", [nv], layout.d_rowadr),
    integers("d_diag", [nv], layout.d_diag),
    integers("d_colind", [layout.d_colind.length()], layout.d_colind),
  ]
}

///|
fn lu_body() -> String {
  let source =
    #|extern "C" __global__ void mr_sparse_lu_factor_solve(wp::launch_bounds_t<1> bounds,MR_LU_ARGS){
    #|  const size_t wid=size_t(blockIdx.x)+size_t(gridDim.x)*(size_t(blockIdx.y)+size_t(gridDim.y)*size_t(blockIdx.z));
    #|  if(wid>=MR_WORLDS || bounds.size!=size_t(MR_WORLDS)*MR_THREADS || bounds.coord_mult!=1 || blockDim.x!=MR_THREADS || threadIdx.x!=0)return;
    #|  int w=int(wid);if(wp::index(failure,w)!=0 MR_DONE_GUARD)return;
    #|  for(int slot=0;slot<MR_ND;++slot)if(!mr_finite(wp::index(lu,w,slot))){mr_fail(failure,w);return;}
    #|  for(int i=0;i<MR_NV;++i)wp::index(solution,w,i)=MR_T(wp::index(d_rownnz,i));
    #|  for(int reverse=0;reverse<MR_NV;++reverse){int i=MR_NV-1-reverse;
    #|    int rem_i=int(wp::index(solution,w,i)),ai=wp::index(d_rowadr,i),ii=ai+rem_i-1;
    #|    wp::index(solution,w,i)=MR_T(rem_i-1);
    #|    MR_T pivot=wp::index(lu,w,ii),unused;if(!mr_inverse(pivot,unused,failure,w,false))return;
    #|    for(int c=0;c<i;++c){int j=i-1-c,rem_j=int(wp::index(solution,w,j)),aj=wp::index(d_rowadr,j),ji=aj+rem_j-1;
    #|      if(wp::index(d_colind,ji)==i){
    #|        --rem_j;wp::index(solution,w,j)=MR_T(rem_j);
    #|        MR_T multiplier=wp::index(lu,w,ji)/pivot;if(!mr_finite(multiplier)){mr_fail(failure,w);return;}
    #|        wp::index(lu,w,ji)=multiplier;
    #|        int icnt=ai,jcnt=aj,jend=aj+rem_j,iend=ai+wp::index(d_rownnz,i);
    #|        while(jcnt<jend){if(icnt>=iend){mr_fail(failure,w);return;}int ci=wp::index(d_colind,icnt),cj=wp::index(d_colind,jcnt);
    #|          if(ci==cj){MR_T value=wp::index(lu,w,jcnt)-wp::index(lu,w,icnt)*multiplier;if(!mr_finite(value)){mr_fail(failure,w);return;}wp::index(lu,w,jcnt)=value;++icnt;++jcnt;}
    #|          else if(ci>cj)++jcnt;else ++icnt;
    #|        }
    #|      }
    #|    }
    #|  }
    #|  for(int reverse=0;reverse<MR_NV;++reverse){int i=MR_NV-1-reverse,diag=wp::index(d_diag,i),adr=wp::index(d_rowadr,i),d1=diag+1,upper=wp::index(d_rownnz,i)-d1;
    #|    MR_T value=wp::index(rhs,w,i);
    #|    for(int j=0;j<upper;++j){int address=adr+d1+j;value-=wp::index(lu,w,address)*wp::index(solution,w,wp::index(d_colind,address));}
    #|    if(!mr_finite(value)){mr_fail(failure,w);return;}wp::index(solution,w,i)=value;
    #|  }
    #|  for(int i=0;i<MR_NV;++i){int diag=wp::index(d_diag,i),adr=wp::index(d_rowadr,i);MR_T value=wp::index(solution,w,i);
    #|    for(int j=0;j<diag;++j){int address=adr+j;value-=wp::index(lu,w,address)*wp::index(solution,w,wp::index(d_colind,address));}
    #|    MR_T denominator=wp::index(lu,w,adr+diag),unused;if(!mr_inverse(denominator,unused,failure,w,false))return;value/=denominator;
    #|    if(!mr_finite(value)){mr_fail(failure,w);return;}wp::index(solution,w,i)=value;
    #|  }
    #|}
  source
}

///|
pub fn lower_lu(request : LuRequest) -> LuLowered raise {
  let metadata = lu_metadata(request)
  let nv = request.layout.d_rownnz.length()
  let nD = request.layout.d_colind.length()
  let params = metadata.map(item => parameter(item.name, "int32", 1, "input"))
  params.push(parameter("rhs", request.dtype, 2, "input"))
  params.push(parameter("solution", request.dtype, 2, "inout"))
  params.push(parameter("lu", request.dtype, 2, "inout"))
  params.push(parameter("failure", "int32", 1, "inout"))
  if request.check_done {
    params.push(parameter("done", "bool", 1, "input"))
  }
  let header = "#define WP_TILE_BLOCK_DIM \{request.block_dim}\n#define WP_ENABLE_MATHDX 0\n#include \"builtin.h\"\n#define MR_T wp::\{request.dtype}\n#define MR_NV \{nv}\n#define MR_ND \{nD}\n#define MR_WORLDS \{request.nworld}\n#define MR_THREADS \{request.block_dim}\n#define MR_DONE_GUARD " +
    (if request.check_done { " || wp::index(done,w)" } else { "" }) +
    "\n#define MR_LU_ARGS " +
    params.map(p => p.c_type + " " + p.name).join(", ") +
    "\nstatic_assert(sizeof(wp::array_t<float>)==56,\"Warp array ABI\");\nstatic_assert(sizeof(wp::launch_bounds_t<1>)==24,\"Warp bounds ABI\");\n"
  let common =
    #|template<class T> __device__ bool mr_finite(T value){return wp::isfinite(value);}
    #|__device__ void mr_fail(wp::array_t<wp::int32> failure,int w){wp::atomic_or(failure,w,1);}
    #|template<class T> __device__ bool mr_inverse(T value,T& result,wp::array_t<wp::int32> failure,int w,bool positive){if(!mr_finite(value)||value==T(0)||(positive&&value<=T(0))){mr_fail(failure,w);result=T(0);return false;}result=T(1)/value;if(!mr_finite(result)){mr_fail(failure,w);return false;}return true;}
  let source = header + common + "\n" + lu_body()
  {
    request,
    source,
    source_sha256: @artifacts.sha256(@utf8.encode(source)),
    specialization_sha256: @artifacts.sha256(
      @utf8.encode(Json(request).stringify()),
    ),
    entries: [
      {
        key: "sparse-lu-factor-solve",
        forward: "mr_sparse_lu_factor_solve",
        launch_shape: [request.nworld * request.block_dim],
        parameters: params,
      },
    ],
    launch_policy: {
      block_dim: request.block_dim,
      forward_smem: 0,
      backward_smem: 0,
      grid_stride: false,
      coord_mult: 1,
    },
    metadata,
    nv,
    nD,
  }
}

///|
pub fn validate_lu_bindings(
  request : LuRequest,
  key : String,
  bindings : Array[Binding],
) -> Unit raise {
  let lowered = lower_lu(request)
  guard key == "sparse-lu-factor-solve" else {
    raise Invalid("unknown sparse LU callable")
  }
  let shapes : Map[String, Array[Int32]] = Map([])
  for item in lowered.metadata {
    shapes[item.name] = item.shape
  }
  shapes["rhs"] = [request.nworld, lowered.nv]
  shapes["solution"] = [request.nworld, lowered.nv]
  shapes["lu"] = [request.nworld, lowered.nD]
  shapes["failure"] = [request.nworld]
  shapes["done"] = [request.nworld]
  // solution is the remaining-row-count scratch before it holds the answer.
  // Aliasing rhs here would destroy the input, unlike mixed solve_LD(res,res).
  checked_bindings(lowered.entries[0].parameters, bindings, shapes, false)
}

///|
pub fn validate_lu_metadata(
  request : LuRequest,
  key : String,
  actual : Array[MetadataInput],
) -> Unit raise {
  guard key == "sparse-lu-factor-solve" else {
    raise Invalid("unknown sparse LU callable")
  }
  checked_metadata(lu_metadata(request), actual)
}
