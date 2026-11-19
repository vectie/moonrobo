// Included after dispatch.cpp's private Device/Buffer definitions. Every vendor
// call uses the real Warp header; this file supplies no replacement declarations.
namespace {
struct CurrentStream {
 Device& d;void* old=nullptr;
 explicit CurrentStream(Device& device):d(device){d.wp_cuda_context_push_current_fn(d.context);old=d.wp_cuda_context_get_stream_fn(d.context);d.wp_cuda_context_set_stream_fn(d.context,d.stream,0);}
 ~CurrentStream(){d.wp_cuda_context_set_stream_fn(d.context,old,0);d.wp_cuda_context_pop_current_fn();}
};
void pristine_void_api(Device& d){const char* before=d.wp_get_error_string_fn();require(!before||!*before,"Warp has an outstanding native error before a void-return primitive; use a clean upstream session");}
void void_api_result(Device& d,const char* operation){const char* after=d.wp_get_error_string_fn();require(!after||!*after,d.vendor(operation).c_str());}
uint64_t typed_span(int count,int stride,int components,int width){
 require(count>=0&&stride>0&&components>0&&components<=INT32_MAX/width&&stride>=components*width&&stride%width==0,"invalid typed scan count, stride or component width");
 return count==0?0:uint64_t(count-1)*uint64_t(stride)+uint64_t(components)*width;
}
void owner(Device& d,mrd_buffer* b,uint64_t offset,uint64_t size,int alignment){buffer_range(b,offset,size);require(b->device.get()==&d,"primitive buffer belongs to another context");require(offset%alignment==0,"typed buffer offset is misaligned");}
void register_base(Device& d,mrd_buffer* b,uint64_t state){if(state){uint32_t id=d.wp_apic_register_memory_region_by_ptr_fn(reinterpret_cast<APICState*>(state),reinterpret_cast<uint64_t>(b->pointer),b->size,1);require(id>0&&id<=INT32_MAX,"primitive base allocation registration failed");}}
}
extern "C" MRD_API int mrd_scan(mrd_context* c,mrd_buffer* input,mrd_buffer* output,uint64_t in_offset,uint64_t out_offset,int type,int count,int in_stride,int out_stride,int components,int inclusive,uint64_t state){return checked([&]{
 require(c&&(inclusive==0||inclusive==1)&&type>=1&&type<=4,"invalid scan context, type or inclusive flag");auto d=c->device;expected_capture(*d,state);const int width=(type==2||type==4)?8:4;
 uint64_t insize=typed_span(count,in_stride,components,width),outsize=typed_span(count,out_stride,components,width);owner(*d,input,in_offset,insize,width);owner(*d,output,out_offset,outsize,width);
 uint64_t in=reinterpret_cast<uint64_t>(input->pointer)+in_offset,out=reinterpret_cast<uint64_t>(output->pointer)+out_offset;
 require(insize==0||outsize==0||out+outsize<=in||in+insize<=out,"scan input/output spans must not overlap");if(!count)return;
 register_base(*d,input,state);register_base(*d,output,state);
 CurrentStream current(*d);pristine_void_api(*d);
 try {switch(type){case 1:d->wp_array_scan_int_device_fn(in,out,count,in_stride,out_stride,components,inclusive!=0);break;case 2:d->wp_array_scan_int64_device_fn(in,out,count,in_stride,out_stride,components,inclusive!=0);break;case 3:d->wp_array_scan_float_device_fn(in,out,count,in_stride,out_stride,components,inclusive!=0);break;default:d->wp_array_scan_double_device_fn(in,out,count,in_stride,out_stride,components,inclusive!=0);}
 void_api_result(*d,"native CUB scan failed");}catch(...){if(state)d->poisoned=true;throw;}
});}
struct mrd_partition {std::shared_ptr<Device> device;void* pointer;int count,num_segments;uint64_t bytes;std::vector<int32_t> host;};
extern "C" MRD_API mrd_partition* mrd_partition_create(mrd_context* c,const uint8_t* wire,size_t bytes,int count){mrd_partition* result=nullptr;checked([&]{
 require(c&&wire&&count>=0&&bytes>=4&&bytes%4==0&&bytes<=4194308,"invalid host segment partition transport");auto d=c->device;d->outside_capture();const size_t n=bytes/4;std::vector<int32_t> values;values.reserve(n);Reader r{wire,bytes};int previous=-1;
 for(size_t i=0;i<n;++i){uint32_t value=r.u32();require(value<=uint32_t(count)&&int(value)>=previous,"segment boundaries must be monotone and lie in [0,count]");previous=int(value);values.push_back(int32_t(value));}
 require(values.front()==0&&values.back()==count&&(count==0||n>=2),"segment partition must begin at zero and end at count");
 pristine_void_api(*d);void* pointer=d->wp_alloc_device_default_fn(d->context,bytes,"moonrobo-immutable-sort-partition");require(pointer,d->vendor("segment boundary allocation failed").c_str());d->allocations.push_back({pointer,bytes});bool ok=d->wp_memcpy_h2d_fn(d->context,pointer,values.data(),bytes,d->stream);d->synchronize();require(ok,d->vendor("segment boundary upload failed").c_str());
 result=new mrd_partition{d,pointer,count,int(n-1),bytes,std::move(values)};
 });return result;}
extern "C" MRD_API void mrd_partition_release(mrd_partition* p){delete p;}
extern "C" MRD_API int mrd_segmented_sort(mrd_context* c,mrd_buffer* keys,mrd_buffer* values,mrd_partition* partition,uint64_t key_offset,uint64_t value_offset,int type,uint64_t state){return checked([&]{
 require(c&&partition&&(type==1||type==3),"segmented sort requires an immutable validated partition and int32/float32 keys");auto d=c->device;expected_capture(*d,state);require(partition->device.get()==d.get(),"segment partition belongs to another context");int count=partition->count,num_segments=partition->num_segments;
 uint64_t bytes=uint64_t(count)*8;owner(*d,keys,key_offset,bytes,4);owner(*d,values,value_offset,bytes,4);
 uint64_t kp=reinterpret_cast<uint64_t>(keys->pointer)+key_offset,vp=reinterpret_cast<uint64_t>(values->pointer)+value_offset,sp=reinterpret_cast<uint64_t>(partition->pointer);
 require(bytes==0||kp+bytes<=vp||vp+bytes<=kp,"key/value double buffers overlap");if(!count)return;
 register_base(*d,keys,state);register_base(*d,values,state);
 if(state){auto apic=reinterpret_cast<APICState*>(state);uint32_t id=d->wp_apic_register_memory_region_by_ptr_fn(apic,sp,partition->bytes,4);require(id>0&&id<=INT32_MAX,"immutable partition region registration failed");d->wp_apic_register_memory_region_fn(apic,id,partition->bytes,4,partition->host.data());}
 CurrentStream current(*d);pristine_void_api(*d);
 try {if(type==1)d->wp_segmented_sort_pairs_int_device_fn(kp,vp,count,sp,sp+4,num_segments);else d->wp_segmented_sort_pairs_float_device_fn(kp,vp,count,sp,sp+4,num_segments);
 void_api_result(*d,"native CUB segmented sort failed");}catch(...){if(state)d->poisoned=true;throw;}
});}
struct mrd_conditional {
 std::shared_ptr<Device> device;
 APICState* state=nullptr;APICBranchStart* start=nullptr;APICBranchBody* bodies[2]={nullptr,nullptr};
 void* outer=nullptr;void* graphs[2]={nullptr,nullptr};uint64_t condition_handle=0;int32_t condition_region=0;
 uint64_t condition_offset=0;void* condition=nullptr;bool is_while=false,use_ptx=false,paused=false,active=false,finished=false,mutated=false;
 int selected=-1;bool captured[2]={false,false};bool needed[2]={false,false};
};
namespace {
void conditional_state(mrd_conditional* b){require(b&&b->device&&!b->finished,"conditional capture is closed");expected_capture(*b->device,reinterpret_cast<uint64_t>(b->state));}
void abort_conditional(mrd_conditional* b){
 if(!b||b->finished)return;auto d=b->device;
 // Cleanup is thread-affine and best effort. A partially inserted CUDA
 // conditional cannot be removed, so the enclosing graph must be discarded.
 if(d->thread!=std::this_thread::get_id()){d->poisoned=true;return;}
 if(b->start){APICBranchBody* partial=d->wp_apic_end_branch_fn(b->state,b->start);b->start=nullptr;if(partial)d->wp_apic_free_branch_body_fn(partial);}
 for(auto& body:b->bodies){if(body){d->wp_apic_free_branch_body_fn(body);body=nullptr;}}
 if(b->active){void* ignored=nullptr;d->wp_cuda_graph_pause_capture_fn(d->context,d->stream,&ignored);b->active=false;}
 if(b->paused&&b->outer){d->wp_cuda_graph_resume_capture_fn(d->context,d->stream,b->outer);b->paused=false;}
 if(b->mutated)d->poisoned=true;b->finished=true;
}
}
extern "C" MRD_API mrd_conditional* mrd_conditional_begin(mrd_context* c,mrd_buffer* condition,uint64_t offset,uint64_t state,int is_while,int use_ptx,int has_true,int has_false){mrd_conditional* result=nullptr;checked([&]{
 require(c&&state&&(is_while==0||is_while==1)&&(use_ptx==0||use_ptx==1)&&(has_true==0||has_true==1)&&(has_false==0||has_false==1),"conditional capture needs an explicit APIC state and boolean flags");auto d=c->device;expected_capture(*d,state);owner(*d,condition,offset,4,4);
 require((is_while&&has_true&&!has_false)||(!is_while&&(has_true||has_false)),"invalid conditional branch selection");
 require(d->wp_cuda_driver_version_fn()>=12040&&d->wp_cuda_toolkit_version_fn()>=12040,"native conditional graph nodes require CUDA toolkit and driver 12.4 or newer");require(d->wp_cuda_stream_is_capturing_fn(d->stream)==1,"conditional capture requires an active outer CUDA graph capture; APIC-only/fixed-repeat substitution is forbidden");
 auto b=std::make_unique<mrd_conditional>();b->device=d;b->state=reinterpret_cast<APICState*>(state);b->condition=static_cast<uint8_t*>(condition->pointer)+offset;b->condition_offset=offset;b->is_while=is_while!=0;b->use_ptx=use_ptx!=0;b->needed[0]=has_true!=0;b->needed[1]=has_false!=0;
 uint32_t region=d->wp_apic_register_memory_region_by_ptr_fn(b->state,reinterpret_cast<uint64_t>(condition->pointer),condition->size,4);require(region>0&&region<=INT32_MAX,"condition region registration failed");b->condition_region=int32_t(region);
 try {
  b->mutated=true;
  bool ok=b->is_while?d->wp_cuda_graph_insert_while_fn(d->context,d->stream,d->arch,b->use_ptx,static_cast<int*>(b->condition),&b->graphs[0],&b->condition_handle):d->wp_cuda_graph_insert_if_else_fn(d->context,d->stream,d->arch,b->use_ptx,static_cast<int*>(b->condition),has_true?&b->graphs[0]:nullptr,has_false?&b->graphs[1]:nullptr);
  require(ok,d->vendor("native conditional graph insertion failed").c_str());require(d->wp_cuda_graph_pause_capture_fn(d->context,d->stream,&b->outer),d->vendor("cannot pause parent graph").c_str());b->paused=true;require(b->outer,"paused parent graph is null");
 }catch(...){abort_conditional(b.get());throw;}
 result=b.release();
 });return result;}
extern "C" MRD_API int mrd_conditional_enter(mrd_conditional* b,int branch){return checked([&]{conditional_state(b);require(branch>=0&&branch<=1&&b->needed[branch]&&!b->captured[branch]&&!b->active&&b->selected==-1,"conditional branch is absent, repeated, or already active");auto d=b->device;b->start=d->wp_apic_begin_branch_fn(b->state);require(b->start,"APIC branch allocation failed");b->selected=branch;require(d->wp_cuda_graph_resume_capture_fn(d->context,d->stream,b->graphs[branch]),d->vendor("cannot resume conditional body graph").c_str());b->active=true;});}
extern "C" MRD_API int mrd_conditional_leave(mrd_conditional* b){return checked([&]{conditional_state(b);require(b->active&&b->selected>=0,"conditional branch is not active");auto d=b->device;int branch=b->selected;
 if(b->is_while)require(d->wp_cuda_graph_set_condition_fn(d->context,d->stream,d->arch,b->use_ptx,static_cast<int*>(b->condition),b->condition_handle),d->vendor("cannot update actual while condition").c_str());
 void* body=nullptr;require(d->wp_cuda_graph_pause_capture_fn(d->context,d->stream,&body),d->vendor("cannot pause conditional body").c_str());b->active=false;
 b->bodies[branch]=d->wp_apic_end_branch_fn(b->state,b->start);b->start=nullptr;require(b->bodies[branch],"APIC branch extraction failed");require(d->wp_cuda_graph_check_conditional_body_fn(b->graphs[branch]),d->vendor("conditional graph contains unsupported operations").c_str());b->captured[branch]=true;b->selected=-1;
});}
extern "C" MRD_API int mrd_conditional_finish(mrd_conditional* b){return checked([&]{conditional_state(b);require(!b->active&&b->selected==-1&&(!b->needed[0]||b->captured[0])&&(!b->needed[1]||b->captured[1]),"conditional branches were not completely captured");auto d=b->device;
 require(d->wp_cuda_graph_resume_capture_fn(d->context,d->stream,b->outer),d->vendor("cannot resume parent graph").c_str());b->paused=false;
 d->wp_apic_record_conditional_fn(b->state,b->is_while?APIC_OP_WHILE:APIC_OP_IF,b->condition_region,b->condition_offset,b->bodies[0],b->bodies[1]);b->bodies[0]=nullptr;b->bodies[1]=nullptr;b->finished=true;
});}
extern "C" MRD_API void mrd_conditional_abort(mrd_conditional* b){abort_conditional(b);}
extern "C" MRD_API void mrd_conditional_release(mrd_conditional* b){abort_conditional(b);delete b;}

struct mrd_graph {std::shared_ptr<Device> device;uint64_t state;void* graph=nullptr;void* exec=nullptr;bool active=false;};
namespace {
void release_graph(mrd_graph* g){
 if(!g)return;auto d=g->device;
 // The API is thread-affine. If a finalizer violates that contract, retain
 // foreign GPU resources rather than destroying capture inputs cross-thread.
 if(d->thread!=std::this_thread::get_id()){d->poisoned=true;return;}
 if(g->active){void* captured=nullptr;bool ok=d->wp_cuda_graph_end_capture_fn(d->context,d->stream,&captured);if(captured)g->graph=captured;g->active=false;d->poisoned=true;if(!ok)d->poisoned=true;}
 if(g->exec){if(d->wp_cuda_stream_is_capturing_fn(d->stream)==0)d->wp_cuda_context_synchronize_fn(d->context);if(!d->wp_cuda_graph_exec_destroy_fn(d->context,g->exec))d->poisoned=true;g->exec=nullptr;}
 if(g->graph){if(!d->wp_cuda_graph_destroy_fn(d->context,g->graph))d->poisoned=true;g->graph=nullptr;}
}
}
extern "C" MRD_API mrd_graph* mrd_graph_begin(mrd_context* c,uint64_t state){mrd_graph* result=nullptr;checked([&]{
 require(c&&state,"native outer graph capture requires an explicit live APIC state");auto d=c->device;expected_capture(*d,state);require(d->wp_cuda_stream_is_capturing_fn(d->stream)==0,"nested outer graph capture is forbidden");
 auto g=std::make_unique<mrd_graph>();g->device=d;g->state=state;
 if(!d->wp_cuda_graph_begin_capture_fn(d->context,d->stream,0,WP_CUDA_GRAPH_CAPTURE_MODE_THREAD_LOCAL)){d->poisoned=true;if(d->wp_cuda_stream_is_capturing_fn(d->stream)>0){void* partial=nullptr;d->wp_cuda_graph_end_capture_fn(d->context,d->stream,&partial);if(partial)d->wp_cuda_graph_destroy_fn(d->context,partial);}throw std::runtime_error(d->vendor("native outer graph begin failed"));}
 g->active=true;result=g.release();
 });return result;}
extern "C" MRD_API int mrd_graph_end(mrd_graph* g){return checked([&]{require(g&&g->active,"outer graph capture is not active");auto d=g->device;expected_capture(*d,g->state);void* graph=nullptr;bool ok=d->wp_cuda_graph_end_capture_fn(d->context,d->stream,&graph);g->active=false;g->graph=graph;if(!ok||!graph){d->poisoned=true;throw std::runtime_error(d->vendor("native outer graph end failed"));}});}
extern "C" MRD_API int mrd_graph_launch(mrd_graph* g){return checked([&]{require(g&&!g->active&&g->graph,"native graph is not finalized");auto d=g->device;d->outside_capture();
 if(!g->exec){void* exec=nullptr;bool ok=d->wp_cuda_graph_create_exec_fn(d->context,d->stream,g->graph,&exec);g->exec=exec;if(!ok||!exec){d->poisoned=true;throw std::runtime_error(d->vendor("native graph instantiation failed"));}}
 if(!d->wp_cuda_graph_launch_fn(g->exec,d->stream)){d->poisoned=true;throw std::runtime_error(d->vendor("native graph launch failed"));}
 });}
extern "C" MRD_API void mrd_graph_release(mrd_graph* g){release_graph(g);delete g;}
