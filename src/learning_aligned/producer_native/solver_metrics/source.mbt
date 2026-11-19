///|
fn common_source() -> String {
  let source =
    #|static __device__ bool mr_finite(float v){return wp::isfinite(v);}
    #|#define MR_REQUIRE(c) do{if(!(c)){wp::atomic_or(failure,w,1);return;}}while(0)
    #|static __device__ void mr_put(wp::array_t<float> out,int w,int i,float value,wp::array_t<int> failure){if(!mr_finite(value))wp::atomic_or(failure,w,1);wp::index(out,w,i)=value;}
    #|static __device__ void mr_chol33(int w,int base,float a,float b,float c,float d,float e,float f,wp::array_t<float> out,wp::array_t<int> failure){
    #| float l00=wp::sqrt(wp::max(1.0e-15f,a)),l10=b/l00,l20=d/l00,l11=wp::sqrt(wp::max(1.0e-15f,c-l10*l10)),l21=(e-l20*l10)/l11,l22=wp::sqrt(wp::max(1.0e-15f,f-(l20*l20+l21*l21)));
    #| mr_put(out,w,base,l00,failure);mr_put(out,w,base+1,0.0f,failure);mr_put(out,w,base+2,0.0f,failure);mr_put(out,w,base+3,l10,failure);mr_put(out,w,base+4,l11,failure);mr_put(out,w,base+5,0.0f,failure);mr_put(out,w,base+6,l20,failure);mr_put(out,w,base+7,l21,failure);mr_put(out,w,base+8,l22,failure);
    #|}
  source
}

///|
fn block_proof(r : Request, map : Bool) -> String {
  let mut result = "for(int k=0;k<\{r.nblock};++k){int i=wp::index(efm_dofid,k);MR_REQUIRE(i>=0&&i<=MR_NV-3);for(int p=0;p<k;++p){int j=wp::index(efm_dofid,p);MR_REQUIRE(i+3<=j||j+3<=i);}}\n"
  if map {
    result += "for(int i=0;i<MR_NV;++i){int k=wp::index(efm_dofblk,i);MR_REQUIRE(k>=-1&&k<\{r.nblock});if(k>=0){int base=wp::index(efm_dofid,k);MR_REQUIRE(i>=base&&i<base+3);}}for(int k=0;k<\{r.nblock};++k)for(int j=0;j<3;++j)MR_REQUIRE(wp::index(efm_dofblk,wp::index(efm_dofid,k)+j)==k);\n"
  }
  result
}

///|
fn force_source(r : Request) -> String {
  let mask = if r.sleep {
    "int tree=wp::index(dof_treeid,i);MR_REQUIRE(tree>=0&&tree<\{r.ntree});if(wp::index(tree_awake,w,tree)==0){wp::index(effective_force,w,i)=0.0f;continue;}"
  } else {
    ""
  }
  "for(int i=0;i<MR_NV;++i){" +
  mask +
  "float a=wp::index(qfrc_smooth,w,i),b=wp::index(efm_c,w,i),c=wp::index(efm_ca,w,i);MR_REQUIRE(mr_finite(a)&&mr_finite(b)&&mr_finite(c));mr_put(effective_force,w,i,a+b+c,failure);}\n"
}

///|
fn solve_source(r : Request, key : String) -> String raise {
  match key {
    "copy-backbone-rhs" =>
      "for(int i=0;i<MR_NV;++i){int k=wp::index(efm_dofblk,i);MR_REQUIRE(k>=-1);float value=k>=0?0.0f:wp::index(rhs,w,i);mr_put(res,w,i,value,failure);}\n"
    "zero-sleeping" =>
      "for(int i=0;i<MR_NV;++i){int tree=wp::index(dof_treeid,i);MR_REQUIRE(tree>=0&&tree<\{r.ntree});if(wp::index(tree_awake,w,tree)==0)wp::index(res,w,i)=0.0f;}\n"
    "block-solve" =>
      block_proof(r, false) +
      "for(int k=0;k<\{r.nblock};++k){int i=wp::index(efm_dofid,k),base=9*k;float a=wp::index(efm_L,w,base),b=wp::index(efm_L,w,base+3),c=wp::index(efm_L,w,base+4),d=wp::index(efm_L,w,base+6),e=wp::index(efm_L,w,base+7),f=wp::index(efm_L,w,base+8);MR_REQUIRE(mr_finite(a)&&mr_finite(b)&&mr_finite(c)&&mr_finite(d)&&mr_finite(e)&&mr_finite(f)&&a>0.0f&&c>0.0f&&f>0.0f);float b0=wp::index(rhs,w,i),b1=wp::index(rhs,w,i+1),b2=wp::index(rhs,w,i+2);float r0=b0/a,r1=(b1-b*r0)/c,r2=(b2-(d*r0+e*r1))/f,x2=r2/f,x1=(r1-e*x2)/c,x0=(r0-b*x1-d*x2)/a;mr_put(res,w,i,x0,failure);mr_put(res,w,i+1,x1,failure);mr_put(res,w,i+2,x2,failure);}\n"
    "efm0-solve" =>
      "for(int i=0;i<\{r.nefm0};++i){int dof=wp::index(efm0_dofid,i),adr=wp::index(efm0_L_rowadr,i),nnz=wp::index(efm0_L_rownnz,i);MR_REQUIRE(dof>=0&&dof<MR_NV&&adr>=0&&nnz>0&&adr<=\{r.nefm0L}-nnz);for(int p=0;p<i;++p)MR_REQUIRE(wp::index(efm0_dofid,p)!=dof);int previous=-1;for(int j=0;j<nnz;++j){int col=wp::index(efm0_L_colind,adr+j);MR_REQUIRE(col>previous&&col<=i&&mr_finite(wp::index(efm0_L,adr+j)));previous=col;}MR_REQUIRE(previous==i&&wp::index(efm0_L,adr+nnz-1)>0.0f);mr_put(res,w,dof,wp::index(rhs,w,dof),failure);}\n" +
      "for(int i=\{r.nefm0}-1;i>=0;--i){int adr=wp::index(efm0_L_rowadr,i),nnz=wp::index(efm0_L_rownnz,i),dof=wp::index(efm0_dofid,i);float value=wp::index(res,w,dof)/wp::index(efm0_L,adr+nnz-1);mr_put(res,w,dof,value,failure);if(value!=0.0f)for(int j=0;j<nnz-1;++j){int target=wp::index(efm0_dofid,wp::index(efm0_L_colind,adr+j));mr_put(res,w,target,wp::index(res,w,target)-wp::index(efm0_L,adr+j)*value,failure);}}\n" +
      "for(int i=0;i<\{r.nefm0};++i){int adr=wp::index(efm0_L_rowadr,i),nnz=wp::index(efm0_L_rownnz,i),dof=wp::index(efm0_dofid,i);float value=wp::index(res,w,dof);for(int j=0;j<nnz-1;++j)value-=wp::index(efm0_L,adr+j)*wp::index(res,w,wp::index(efm0_dofid,wp::index(efm0_L_colind,adr+j)));mr_put(res,w,dof,value/wp::index(efm0_L,adr+nnz-1),failure);}\n"
    _ => fail("unknown metric solve helper")
  }
}

///|
fn blocks_source(r : Request, key : String) -> String {
  if key == "factor-folded-blocks" {
    return "for(int k=0;k<\{r.nblock};++k){int b=9*k;float a=wp::index(epB,w,b),c=wp::index(epB,w,b+4),f=wp::index(epB,w,b+8),v1=wp::index(epB,w,b+3),v2=wp::index(epB,w,b+6),v3=wp::index(epB,w,b+7);MR_REQUIRE(mr_finite(a)&&mr_finite(c)&&mr_finite(f)&&mr_finite(v1)&&mr_finite(v2)&&mr_finite(v3));mr_chol33(w,b,a,v1,c,v2,v3,f,epL,failure);}\n"
  }
  let mut body = block_proof(r, false) +
    "for(int k=0;k<\{r.nblock};++k){int i=wp::index(efm_dofid,k);float B[9]={};for(int rr=0;rr<3;++rr){int row=i+rr,adr=wp::index(M_rowadr,row),nnz=wp::index(M_rownnz,row);MR_REQUIRE(adr>=0&&nnz>0&&adr<=\{r.nC}-nnz);for(int a=0;a<nnz;++a){int c=wp::index(M_colind,adr+a);float value=wp::index(M,w,adr+a);MR_REQUIRE(c>=0&&c<MR_NV&&mr_finite(value));if(c>=i&&c<i+3)B[3*rr+c-i]+=value;}adr=wp::index(K_rowadr,row);nnz=wp::index(K_rownnz,row);MR_REQUIRE(adr>=0&&nnz>=0&&adr<=\{r.nK}-nnz);for(int a=0;a<nnz;++a){int c=wp::index(K_colind,adr+a);float value=wp::index(K_val,w,adr+a);MR_REQUIRE(c>=0&&c<MR_NV&&mr_finite(value));if(c>=i&&c<i+3)B[3*rr+c-i]+=value;}}\n"
  if key == "build-blocks" && !r.sparse_jacobian && r.njmax > 0 {
    body += "int count=wp::index(nefc,w);MR_REQUIRE(count>=0&&count<=\{r.njmax});for(int row=0;row<count;++row){float D=wp::index(efc_D,w,row);MR_REQUIRE(mr_finite(D));if(D!=0.0f){float J[3]={wp::index(efc_J,w,row,i),wp::index(efc_J,w,row,i+1),wp::index(efc_J,w,row,i+2)};MR_REQUIRE(mr_finite(J[0])&&mr_finite(J[1])&&mr_finite(J[2]));if(J[0]!=0.0f||J[1]!=0.0f||J[2]!=0.0f)for(int rr=0;rr<3;++rr)for(int cc=0;cc<3;++cc)B[3*rr+cc]+=D*J[rr]*J[cc];}}\n"
  }
  if key == "build-blocks" {
    body += "for(int j=0;j<9;++j)mr_put(epB,w,9*k+j,B[j],failure);"
  } else {
    body += "for(int j=0;j<9;++j)MR_REQUIRE(mr_finite(B[j]));mr_chol33(w,9*k,B[0],B[3],B[4],B[6],B[7],B[8],efm_L,failure);"
  }
  body + "}\n"
}

///|
fn rank1_source(r : Request, key : String) -> String {
  let fold = key.has_prefix("fold-")
  let diag = key.has_suffix("qh-diag")
  let tendon = key.contains("tendon")
  let actuator = key.contains("actuator")
  let efc = key == "fold-efc-sparse"
  let count = if tendon {
    r.ntendon
  } else if actuator {
    r.nactuator
  } else if efc {
    r.njmax
  } else {
    r.ncon
  }
  let capacity = if tendon {
    r.tendon_nnz
  } else if actuator {
    r.moment_nnz
  } else if efc {
    r.jacobian_nnz
  } else {
    r.contact_width
  }
  let column = if tendon {
    "wp::index(ten_colind,adr+j)"
  } else if actuator {
    "wp::index(moment_colind,w,adr+j)"
  } else if efc {
    "wp::index(efc_J_colind,w,0,adr+j)"
  } else {
    "wp::index(contact_dof,row,j)"
  }
  let value = if tendon {
    "wp::index(ten_J,w,adr+j)"
  } else if actuator {
    "wp::index(actuator_moment,w,adr+j)"
  } else if efc {
    "wp::index(efc_J,w,0,adr+j)"
  } else {
    "wp::index(contact_val,row,j)"
  }
  let scale = if tendon {
    "wp::index(efm_ts,w,row)"
  } else if actuator {
    "wp::index(efm_as,w,row)"
  } else if efc {
    "wp::index(efc_D,w,row)"
  } else {
    "wp::index(contact_scale,row)"
  }
  let descriptor = if tendon {
    "int adr=wp::index(ten_rowadr,row),nnz=wp::index(ten_rownnz,row);"
  } else if actuator {
    "int adr=wp::index(moment_rowadr,w,row),nnz=wp::index(moment_rownnz,w,row);"
  } else if efc {
    "int adr=wp::index(efc_J_rowadr,w,row),nnz=wp::index(efc_J_rownnz,w,row);"
  } else {
    "int adr=0,nnz=wp::index(contact_nnz,row);"
  }
  let mut body = if fold { block_proof(r, true) } else { "" }
  if efc {
    body += "int count=wp::index(nefc,w);MR_REQUIRE(count>=0&&count<=\{r.njmax});"
  }
  if !tendon && !actuator && !efc && fold {
    body += "int count=wp::index(nacon,0);MR_REQUIRE(count>=0&&count<=\{r.ncon});"
  }
  body += "for(int row=0;row<\{count};++row){"
  if efc || (!tendon && !actuator && fold) {
    body += "if(row>=count)break;"
  }
  if !tendon && !actuator && !efc {
    body += "int nn=wp::index(contact_nnz,row);MR_REQUIRE(nn>=0&&nn<=\{r.contact_width});if(nn==0)continue;int world=wp::index(contact_worldid,row);MR_REQUIRE(world>=0&&world<\{r.nworld});if(world!=w)continue;"
  }
  body += "float scale=" +
    scale +
    ";MR_REQUIRE(mr_finite(scale));if(scale==0.0f)continue;" +
    descriptor +
    "MR_REQUIRE(adr>=0&&nnz>=0&&adr<=\{capacity}-nnz);for(int j=0;j<nnz;++j){int dof=" +
    column +
    ";float value=" +
    value +
    ";MR_REQUIRE(dof>=0&&dof<MR_NV&&mr_finite(value));}\n"
  if fold {
    body += "for(int a=0;a<nnz;++a){int j=a,ia=" +
      column +
      ",k=wp::index(efm_dofblk,ia);if(k<0)continue;int base=wp::index(efm_dofid,k);float sva=scale*(" +
      value +
      ");for(int b=0;b<nnz;++b){j=b;int ib=" +
      column +
      ";if(wp::index(efm_dofblk,ib)==k){int slot=9*k+3*(ia-base)+(ib-base);mr_put(epB,w,slot,wp::index(epB,w,slot)+sva*(" +
      value +
      "),failure);}}}\n"
  } else if diag {
    body += "for(int j=0;j<nnz;++j){int dof=" +
      column +
      ",ma=wp::index(M_rowadr,dof),mn=wp::index(M_rownnz,dof);MR_REQUIRE(ma>=0&&mn>0&&ma<=\{r.nC}-mn);float v=" +
      value +
      ";int slot=ma+mn-1;mr_put(qH,w,slot,wp::index(qH,w,slot)+scale*v*v,failure);}\n"
  } else {
    body += "float dot=0.0f;for(int j=0;j<nnz;++j)dot+=(" +
      value +
      ")*wp::index(vec,w," +
      column +
      ");dot*=scale;for(int j=0;j<nnz;++j){int dof=" +
      column +
      ";mr_put(res,w,dof,wp::index(res,w,dof)+dot*(" +
      value +
      "),failure);}\n"
  }
  body + "}\n"
}

///|
fn simple_source(r : Request, key : String) -> String raise {
  match key {
    "mul-diag" =>
      "for(int i=0;i<MR_NV;++i){float value=wp::index(efm_diag,w,i)*wp::index(vec,w,i);mr_put(res,w,i,wp::index(res,w,i)+value,failure);}\n"
    "mul-diag-csr" =>
      "for(int i=0;i<MR_NV;++i){float value=wp::index(efm_diag,w,i)*wp::index(vec,w,i);int nnz=wp::index(K_rownnz,i),adr=wp::index(K_rowadr,i);MR_REQUIRE(nnz>=0&&adr>=0&&adr<=\{r.nK}-nnz);for(int j=0;j<nnz;++j){int k=adr+j,col=wp::index(K_colind,k);MR_REQUIRE(col>=0&&col<MR_NV);value+=wp::index(K_val,w,k)*wp::index(vec,w,col);}mr_put(res,w,i,wp::index(res,w,i)+value,failure);}\n"
    "mul-fluid" =>
      "for(int i=0;i<MR_NV;++i){float value=0.0f;int begin=wp::index(M_mulm_rowadr,i),end=wp::index(M_mulm_rowadr,i+1);MR_REQUIRE(begin>=0&&end>=begin&&end<=\{2*r.nC-r.nv});for(int k=begin;k<end;++k){int col=wp::index(M_mulm_col,k),madr=wp::index(M_mulm_madr,k);MR_REQUIRE(col>=0&&col<MR_NV&&madr>=0&&madr<\{r.nC});value+=wp::index(efm_fluid,w,madr)*wp::index(vec,w,col);}mr_put(res,w,i,wp::index(res,w,i)+value,failure);}\n"
    "add-qh-diag" =>
      "for(int i=0;i<MR_NV;++i){int adr=wp::index(M_rowadr,i),nnz=wp::index(M_rownnz,i);MR_REQUIRE(adr>=0&&nnz>0&&adr<=\{r.nC}-nnz);int slot=adr+nnz-1;mr_put(qH,w,slot,wp::index(qH,w,slot)+wp::index(efm_diag,w,i),failure);}\n"
    "add-fluid-qh" =>
      "for(int i=0;i<\{r.nC};++i)mr_put(qH,w,i,wp::index(qH,w,i)+wp::index(efm_fluid,w,i),failure);\n"
    _ => fail("unknown simple metric helper")
  }
}
