// Compile this adapter WITH the SDK C++ sources/libraries, not as a MoonBit stub.
// No Python/pybind dependency. SDK DDS configuration remains CYCLONEDDS_URI.
#include <highcontroller.h>
#include <chrono>
#include <exception>
#include <cstdio>
using legged::HighController;
extern "C" int moonrobo_e1_init(char *error,int capacity){
 try {if(!HighController::Instance()->init()){std::snprintf(error,capacity,"HighController::init returned false");return -1;}return 0;}
 catch(const std::exception &e){std::snprintf(error,capacity,"%s",e.what());return -1;}
 catch(...){std::snprintf(error,capacity,"SDK initialization exception");return -1;}
}
extern "C" int moonrobo_e1_capture(double *out,char *error,int capacity){
 try{
  auto started=std::chrono::steady_clock::now();auto *c=HighController::Instance();
  int mode=c->get_mode();auto joints=c->get_joint_state();auto imu=c->get_imu_data();auto joy=c->from_dds_get_joydata();
  for(int i=0;i<24;i++){out[i*6]=joints[i].motor_id;out[i*6+1]=joints[i].pos;out[i*6+2]=joints[i].vel;out[i*6+3]=joints[i].tau;out[i*6+4]=joints[i].error;out[i*6+5]=joints[i].temperature;}
  for(int i=0;i<4;i++)out[144+i]=imu.ori[i];
  for(int i=0;i<3;i++){out[148+i]=imu.angular_vel[i];out[151+i]=imu.linear_acc[i];}
  for(int i=0;i<2;i++)out[154+i]=joy.axes[i];
  for(int i=0;i<14;i++)out[156+i]=joy.button[i];
  out[170]=mode;out[171]=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-started).count();return 0;
 }catch(const std::exception &e){std::snprintf(error,capacity,"%s",e.what());return -1;}
 catch(...){std::snprintf(error,capacity,"SDK capture exception");return -1;}
}
extern "C" int moonrobo_e1_publish(double vertical,double horizontal,int action,int data,char *error,int capacity){
 try{if(action!=0&&action!=4&&action!=12){std::snprintf(error,capacity,"unsupported action");return -1;}
 HighController::Instance()->publish_cmd(vertical,horizontal,static_cast<legged::ControlCmd>(action),static_cast<uint16_t>(data));return 0;
 }catch(const std::exception &e){std::snprintf(error,capacity,"%s",e.what());return -1;}
 catch(...){std::snprintf(error,capacity,"SDK publish exception");return -1;}
}
