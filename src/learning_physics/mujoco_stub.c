#include <moonbit.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <dlfcn.h>
#if __has_include(<mujoco/mujoco.h>)
#include <mujoco/mujoco.h>
#define HAVE_MUJOCO 1
#endif
/* Missing native dependencies fail at construction, never synthetic physics. */
typedef struct {
 char error[1024];
#ifdef HAVE_MUJOCO
 void *library; mjModel *m; mjData *d; mjtNum *snapshot; mjtNum *saved; mjtNum *base_ipos; mjtNum *jacp; mjtNum jac_point[3]; mjtNum velocity[6]; int root,base_disable;
 mjModel *(*loadXML)(const char *,const mjVFS *,char *,int);
 mjData *(*makeData)(const mjModel *);
 void (*deleteData)(mjData *); void (*deleteModel)(mjModel *);
 void (*step)(const mjModel *,mjData *); void (*forward)(const mjModel *,mjData *);
 int (*name2id)(const mjModel *,int,const char *);
 const char *(*id2name)(const mjModel *,int,int);
 const char *(*versionString)(void);
 void (*reset)(const mjModel *,mjData *,int);
 void (*resetData)(const mjModel *,mjData *);
 void (*jac)(const mjModel *,const mjData *,mjtNum *,mjtNum *,const mjtNum *,int);
 void (*normalizeQuat)(const mjModel *,mjtNum *);
 void (*objectVelocity)(const mjModel *,const mjData *,int,int,mjtNum *,int);
 mjtNum (*geomDistance)(const mjModel *,const mjData *,int,int,mjtNum,mjtNum *);
 int (*stateSize)(const mjModel *,unsigned int);
 void (*getState)(const mjModel *,const mjData *,mjtNum *,unsigned int);
 void (*setState)(const mjModel *,mjData *,const mjtNum *,unsigned int);
#endif
} Runtime;
static moonbit_bytes_t text_bytes(const char *s){int n=strlen(s);moonbit_bytes_t b=moonbit_make_bytes(n,0);memcpy(b,s,n);return b;}
static void cleanup(void *p){
#ifdef HAVE_MUJOCO
 Runtime *r=p;free(r->snapshot);free(r->saved);free(r->base_ipos);free(r->jacp);if(r->d)r->deleteData(r->d);if(r->m)r->deleteModel(r->m);if(r->library)dlclose(r->library);
#endif
}
MOONBIT_FFI_EXPORT Runtime *moonrobo_mj_open(const unsigned char *lib,const unsigned char *scene,int32_t require_servos){
 Runtime *r=moonbit_make_external_object(cleanup,sizeof(Runtime));memset(r,0,sizeof(*r));
#ifdef HAVE_MUJOCO
 r->library=dlopen((const char *)lib,RTLD_NOW|RTLD_LOCAL);if(!r->library){snprintf(r->error,sizeof(r->error),"%s",dlerror());return r;}
 int (*version)(void);*(void **)(&version)=dlsym(r->library,"mj_version");
 if(!version){snprintf(r->error,sizeof(r->error),"MuJoCo library is missing mj_version: %s",(const char *)lib);return r;}
 int runtime_version=version();
 if(runtime_version!=mjVERSION_HEADER){
   const char *(*version_string)(void);*(void **)(&version_string)=dlsym(r->library,"mj_versionString");
   snprintf(r->error,sizeof(r->error),"MuJoCo ABI mismatch: compiled header mjVERSION_HEADER=%d, loaded runtime mj_version()=%d (%s). Rebuild the native executable with the headers shipped with this exact MuJoCo library; do not bypass the ABI guard.",mjVERSION_HEADER,runtime_version,version_string?version_string():"unknown version");
   return r;
 }
#define LOAD(field,symbol) do{*(void **)(&r->field)=dlsym(r->library,symbol);if(!r->field){snprintf(r->error,sizeof(r->error),"missing MuJoCo symbol %s",symbol);return r;}}while(0)
 LOAD(loadXML,"mj_loadXML");LOAD(makeData,"mj_makeData");LOAD(deleteData,"mj_deleteData");LOAD(deleteModel,"mj_deleteModel");LOAD(step,"mj_step");LOAD(forward,"mj_forward");LOAD(name2id,"mj_name2id");LOAD(id2name,"mj_id2name");LOAD(versionString,"mj_versionString");LOAD(reset,"mj_resetDataKeyframe");LOAD(stateSize,"mj_stateSize");LOAD(getState,"mj_getState");LOAD(setState,"mj_setState");
 LOAD(resetData,"mj_resetData");
 LOAD(jac,"mj_jac");
 LOAD(normalizeQuat,"mj_normalizeQuat");
 LOAD(objectVelocity,"mj_objectVelocity");
#undef LOAD
 r->m=r->loadXML((const char *)scene,NULL,r->error,sizeof(r->error));if(!r->m)return r;
 mjModel *m=r->m;if(m->njnt<2||m->jnt_type[0]!=mjJNT_FREE||!m->nu){strcpy(r->error,"expected floating base and scalar joint actuators");return r;}
 for(int i=0;i<m->nu;i++){int j=m->actuator_trnid[2*i];if(m->actuator_trntype[i]!=mjTRN_JOINT||m->jnt_type[j]!=mjJNT_HINGE||(require_servos&&fabs(m->actuator_biasprm[i*mjNBIAS+1]+m->actuator_gainprm[i*mjNGAIN])>1e-8)){strcpy(r->error,"expected hinge joint actuators with declared servo semantics");return r;}}
 r->d=r->makeData(m);if(!r->d){strcpy(r->error,"mj_makeData failed");return r;}
 r->snapshot=calloc(r->stateSize(m,mjSTATE_INTEGRATION),sizeof(mjtNum));if(!r->snapshot){strcpy(r->error,"snapshot allocation failed");return r;}
 r->saved=calloc(r->stateSize(m,mjSTATE_INTEGRATION),sizeof(mjtNum));if(!r->saved){strcpy(r->error,"saved-state allocation failed");return r;}
 r->base_ipos=malloc(m->nbody*3*sizeof(mjtNum));if(!r->base_ipos){strcpy(r->error,"COM allocation failed");return r;}memcpy(r->base_ipos,m->body_ipos,m->nbody*3*sizeof(mjtNum));
 r->jacp=calloc(3*m->nv,sizeof(mjtNum));if(!r->jacp){strcpy(r->error,"jacobian allocation failed");return r;}
 r->root=m->jnt_bodyid[0];r->base_disable=m->opt.disableflags;
#else
 (void)lib;(void)scene;(void)require_servos;strcpy(r->error,"MuJoCo C headers were unavailable when this executable was built (compiled header version=0). Set CPATH to the matching MuJoCo installation's include directory containing mujoco/mujoco.h, force recompilation of src/learning_physics/mujoco_stub.c, and rebuild. Supplying --library at runtime cannot add omitted C struct bindings.");
#endif
 return r;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_mj_error(Runtime *r){return text_bytes(r->error);}
MOONBIT_FFI_EXPORT int32_t moonrobo_mj_header_version(void){
#ifdef HAVE_MUJOCO
 return mjVERSION_HEADER;
#else
 return 0;
#endif
}
MOONBIT_FFI_EXPORT int32_t moonrobo_mj_count(Runtime *r,int32_t f){
#ifdef HAVE_MUJOCO
 switch(f){case 0:return r->m->nq;case 1:return r->m->nv;case 2:return r->m->na;case 3:return r->m->nu;case 4:return r->stateSize(r->m,mjSTATE_INTEGRATION);case 5:return r->d->ncon;case 6:return r->m->nbody;case 7:return r->m->njnt;case 8:return r->m->nsite;case 9:return r->m->ngeom;}
#endif
 return 0;
}
MOONBIT_FFI_EXPORT double moonrobo_mj_value(Runtime *r,int32_t f,int32_t i){
#ifdef HAVE_MUJOCO
 mjModel *m=r->m;mjData *d=r->d;int nu=m->nu;
 switch(f){case 0:if(i<m->nq)return d->qpos[i];i-=m->nq;if(i<m->nv)return d->qvel[i];return d->act[i-m->nv];
 case 1:if(i<nu)return d->qpos[m->jnt_qposadr[m->actuator_trnid[2*i]]];i-=nu;if(i<nu)return d->qvel[m->jnt_dofadr[m->actuator_trnid[2*i]]];i-=nu;if(i<3)return -d->xmat[9*r->root+6+i];return d->qvel[i];
 case 2:return m->actuator_ctrllimited[i]?m->actuator_ctrlrange[2*i]:-INFINITY;case 3:return m->actuator_ctrllimited[i]?m->actuator_ctrlrange[2*i+1]:INFINITY;
 case 4:return d->xpos[3*r->root+2];case 5:return d->xmat[9*r->root+8];case 6:return m->opt.timestep;case 7:return m->jnt_qposadr[m->actuator_trnid[2*i]];case 8:return r->snapshot[i];case 9:return m->jnt_dofadr[m->actuator_trnid[2*i]];
 case 10:return m->body_parentid[i];case 11:return m->body_jntnum[i];case 12:return m->body_jntadr[i];case 13:return m->body_pos[i];case 14:return m->body_quat[i];case 15:return m->jnt_type[i];case 16:return m->qpos0[m->jnt_qposadr[i]];case 17:return m->jnt_axis[i];case 18:return m->jnt_pos[i];case 19:return m->jnt_limited[i/2]?m->jnt_range[i]:(i%2?INFINITY:-INFINITY);case 20:return m->jnt_qposadr[i];case 21:return m->jnt_dofadr[i];case 22:return d->xpos[i];case 23:return d->xquat[i];case 24:return m->body_mass[i];case 25:return m->body_ipos[i];case 26:return m->body_mocapid[i];case 27:return m->site_bodyid[i];case 28:return m->site_pos[i];case 29:return d->site_xpos[i];case 30:return d->subtree_com[i];case 31:return d->qfrc_bias[i];case 32:return m->actuator_gainprm[i*mjNGAIN];case 33:return r->root;case 34:return r->jacp[i];case 35:return m->opt.gravity[i];case 36:return d->xmat[i];case 37:return r->velocity[i];case 38:return d->actuator_force[i];
 case 39:return -m->actuator_biasprm[i*mjNBIAS+2];
 case 40:return m->actuator_forcerange[2*i];
 case 41:return m->actuator_forcerange[2*i+1];
 case 42:return m->dof_armature[m->jnt_dofadr[m->actuator_trnid[2*i]]];
 case 43:return m->geom_friction[i];
 case 44:return d->qfrc_applied[i];
 case 45:{int worst=-1;double depth=0;for(int c=0;c<d->ncon;c++){const mjContact *x=&d->contact[c];if(x->geom[0]>=0&&x->geom[1]>=0&&m->geom_bodyid[x->geom[0]]>0&&m->geom_bodyid[x->geom[1]]>0&&-x->dist>depth){depth=-x->dist;worst=c;}}return worst<0?0:m->geom_bodyid[d->contact[worst].geom[i]];}
 case 46:{const mjContact *c=&d->contact[i/9];int k=i%9;if(k<2)return c->geom[k]<0?-1:m->geom_bodyid[c->geom[k]];if(k<5)return c->pos[k-2];if(k<8)return c->frame[k-5];return c->dist;}}
#endif
 return NAN;
}
/* Signed collision-geometry distance to world planes, never a body-origin proxy. */
MOONBIT_FFI_EXPORT double moonrobo_mj_floor_distance(Runtime *r,int32_t body){
#ifdef HAVE_MUJOCO
 if(body<=0||body>=r->m->nbody)return NAN;
 if(!r->geomDistance)*(void **)(&r->geomDistance)=dlsym(r->library,"mj_geomDistance");
 if(!r->geomDistance)return NAN;
 double nearest=INFINITY;
 for(int i=0;i<r->m->ngeom;i++)if(r->m->geom_bodyid[i]==body&&(r->m->geom_contype[i]||r->m->geom_conaffinity[i]))
  for(int p=0;p<r->m->ngeom;p++)if(r->m->geom_bodyid[p]==0&&r->m->geom_type[p]==mjGEOM_PLANE){
   double d=r->geomDistance(r->m,r->d,i,p,10.0,NULL);if(d<nearest)nearest=d;
  }
 return nearest;
#else
 return NAN;
#endif
}
MOONBIT_FFI_EXPORT double moonrobo_mj_self_penetration(Runtime *r){
#ifdef HAVE_MUJOCO
 double depth=0;
 for(int i=0;i<r->d->ncon;i++){const mjContact *c=&r->d->contact[i];
  if(c->geom[0]>=0&&c->geom[1]>=0&&r->m->geom_bodyid[c->geom[0]]>0&&r->m->geom_bodyid[c->geom[1]]>0&&-c->dist>depth)depth=-c->dist;
 }
 return depth;
#else
 return NAN;
#endif
}
/* Box support metadata: reject unsupported or ambiguous collision geometry. */
MOONBIT_FFI_EXPORT double moonrobo_mj_body_box(Runtime *r,int32_t body,int32_t field){
#ifdef HAVE_MUJOCO
 int found=-1;
 for(int g=0;g<r->m->ngeom;g++)if(r->m->geom_bodyid[g]==body&&(r->m->geom_contype[g]||r->m->geom_conaffinity[g])){
  if(found>=0||r->m->geom_type[g]!=mjGEOM_BOX||fabs(r->m->geom_quat[4*g]-1)>1e-12)return NAN;found=g;
 }
 if(found<0)return NAN;
 return field<3?r->m->geom_pos[3*found+field]:r->m->geom_size[3*found+field-3];
#else
 return NAN;
#endif
}
MOONBIT_FFI_EXPORT void moonrobo_mj_set(Runtime *r,int32_t f,int32_t i,double v){
#ifdef HAVE_MUJOCO
 if(f==0)r->d->ctrl[i]=v;else if(f==1)r->d->qvel[r->m->jnt_dofadr[r->m->actuator_trnid[2*i]]]=v;else if(f==2)r->d->qpos[i]=v;else if(f==3)r->snapshot[i]=v;else if(f==4){for(int j=0;j<r->m->ngeom;j++)r->m->geom_friction[3*j]=v;for(int j=0;j<r->m->npair;j++)r->m->pair_friction[5*j]=r->m->pair_friction[5*j+1]=v;}else if(f==5){if(i<r->m->nq)r->d->qpos[i]=v;else if(i<r->m->nq+r->m->nv)r->d->qvel[i-r->m->nq]=v;else r->d->act[i-r->m->nq-r->m->nv]=v;}
 else if(f==6){r->m->actuator_gainprm[i*mjNGAIN]=v;r->m->actuator_biasprm[i*mjNBIAS]=0;r->m->actuator_biasprm[i*mjNBIAS+1]=-v;r->m->actuator_ctrlrange[2*i]=-1e6;r->m->actuator_ctrlrange[2*i+1]=1e6;}
 else if(f==7)r->m->actuator_biasprm[i*mjNBIAS+2]=-v;
 else if(f==8){r->m->actuator_forcelimited[i]=1;r->m->actuator_forcerange[2*i]=-v;r->m->actuator_forcerange[2*i+1]=v;}
 else if(f==9)r->m->dof_armature[r->m->jnt_dofadr[r->m->actuator_trnid[2*i]]]=v;
 else if(f==10)r->m->opt.timestep=v;
 else if(f==11){for(int j=0;j<r->m->ngeom;j++){if(r->m->geom_bodyid[j]==0){r->m->geom_contype[j]=1;r->m->geom_conaffinity[j]=2;}else if(r->m->geom_contype[j]!=0||r->m->geom_conaffinity[j]!=0||r->m->geom_group[j]==3||r->m->geom_group[j]==4){r->m->geom_contype[j]=2;r->m->geom_conaffinity[j]=v?3:1;}}}
 else if(f==12){for(int j=0;j<r->m->ngeom;j++)if(r->m->geom_bodyid[j]==0)r->m->geom_friction[3*j]=v;}
 else if(f==13)r->m->body_ipos[i]=r->base_ipos[i]+v;
 else if(f==14)r->jac_point[i]=v;
 else if(f==15)r->jac(r->m,r->d,r->jacp,NULL,r->jac_point,i);
 else if(f==16)r->objectVelocity(r->m,r->d,mjOBJ_BODY,i,r->velocity,0);
 else if(f==17)r->m->opt.disableflags=r->base_disable;
#endif
}
MOONBIT_FFI_EXPORT int32_t moonrobo_mj_reset(Runtime *r,const unsigned char *key,double friction,int32_t unpowered){
#ifdef HAVE_MUJOCO
 int k=r->name2id(r->m,mjOBJ_KEY,(const char *)key);if(k<0){strcpy(r->error,"missing keyframe");return -1;}r->reset(r->m,r->d,k);r->m->opt.disableflags=r->base_disable|(unpowered?mjDSBL_ACTUATION:0);
 for(int i=0;i<r->m->ngeom;i++)r->m->geom_friction[3*i]=friction;
 for(int i=0;i<r->m->npair;i++)r->m->pair_friction[5*i]=r->m->pair_friction[5*i+1]=friction;
 r->forward(r->m,r->d);return 0;
#else
 return -1;
#endif
}
MOONBIT_FFI_EXPORT void moonrobo_mj_step(Runtime *r,int32_t n){
#ifdef HAVE_MUJOCO
 if(n==-1){r->resetData(r->m,r->d);return;}if(n==-2)r->normalizeQuat(r->m,r->d->qpos);for(int i=0;i<n;i++)r->step(r->m,r->d);r->forward(r->m,r->d);
#endif
}
MOONBIT_FFI_EXPORT void moonrobo_mj_snapshot(Runtime *r,int32_t restore){
#ifdef HAVE_MUJOCO
 if(restore){r->setState(r->m,r->d,r->snapshot,mjSTATE_INTEGRATION);r->forward(r->m,r->d);r->setState(r->m,r->d,r->snapshot,mjSTATE_INTEGRATION);}else r->getState(r->m,r->d,r->snapshot,mjSTATE_INTEGRATION);
#endif
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_mj_name(Runtime *r,int32_t i){
#ifdef HAVE_MUJOCO
 if(i<0)return text_bytes(r->versionString());
 if(i>=4000000){const char *n=r->id2name(r->m,mjOBJ_GEOM,i-4000000);return text_bytes(n?n:"");}
 if(i>=3000000){const char *n=r->id2name(r->m,mjOBJ_SITE,i-3000000);return text_bytes(n?n:"");}
 if(i>=2000000){const char *n=r->id2name(r->m,mjOBJ_JOINT,i-2000000);return text_bytes(n?n:"");}
 if(i>=1000000){const char *n=r->id2name(r->m,mjOBJ_BODY,i-1000000);return text_bytes(n?n:"");}
 const char *n=r->id2name(r->m,mjOBJ_JOINT,r->m->actuator_trnid[2*i]);return text_bytes(n?n:"");
#else
 return text_bytes("");
#endif
}
/* Raw URDF/MJCF compilation deliberately bypasses runtime actuator validation. */
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_mj_compile(const unsigned char *lib,const unsigned char *source,const unsigned char *output){
#ifdef HAVE_MUJOCO
 char error[2048]={0};void *handle=dlopen((const char *)lib,RTLD_NOW|RTLD_LOCAL);
 if(!handle){snprintf(error,sizeof(error),"error: %s",dlerror());return text_bytes(error);}
 mjModel *(*load)(const char *,const mjVFS *,char *,int);int (*save)(const char *,const mjModel *,char *,int);void (*destroy)(mjModel *);int (*version)(void);const char *(*version_string)(void);
 *(void **)(&load)=dlsym(handle,"mj_loadXML");*(void **)(&save)=dlsym(handle,"mj_saveLastXML");*(void **)(&destroy)=dlsym(handle,"mj_deleteModel");*(void **)(&version)=dlsym(handle,"mj_version");*(void **)(&version_string)=dlsym(handle,"mj_versionString");
 if(!load||!save||!destroy||!version||!version_string){dlclose(handle);return text_bytes("error: missing required MuJoCo XML compilation symbols");}
 if(version()!=mjVERSION_HEADER){snprintf(error,sizeof(error),"error: MuJoCo ABI mismatch: compiled header=%d, loaded runtime=%d (%s); rebuild with headers from the selected library installation",mjVERSION_HEADER,version(),version_string());dlclose(handle);return text_bytes(error);}
 mjModel *model=load((const char *)source,NULL,error+7,sizeof(error)-7);
 if(!model){memcpy(error,"error: ",7);dlclose(handle);return text_bytes(error);}
 int ok=save((const char *)output,model,error+7,sizeof(error)-7);destroy(model);
 moonbit_bytes_t result;
 if(ok){result=text_bytes(version_string());}else{memcpy(error,"error: ",7);result=text_bytes(error);}
 dlclose(handle);return result;
#else
 (void)lib;(void)source;(void)output;return text_bytes("error: MuJoCo C headers unavailable at build time");
#endif
}
/* Separate save slot: set_integration/integration must not overwrite save(). */
MOONBIT_FFI_EXPORT void moonrobo_mj_saved(Runtime *r,int32_t restore){
#ifdef HAVE_MUJOCO
 if(restore){r->setState(r->m,r->d,r->saved,mjSTATE_INTEGRATION);r->forward(r->m,r->d);r->setState(r->m,r->d,r->saved,mjSTATE_INTEGRATION);}else r->getState(r->m,r->d,r->saved,mjSTATE_INTEGRATION);
#endif
}
