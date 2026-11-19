///|
// Port of fixed pinned IsaacLab kernels (BSD-3-Clause); this keeps every input,
// ordering direction, conditional write, acceleration reset and telemetry branch.
fn body(key : String) -> String raise {
  match key {
    "root-pose-mask" =>
      (
        #|if(wp::index(env_mask,i)) wp::index(root_link_pose_w,i)=wp::index(data,i);
      )
    "root-velocity-mask" =>
      (
        #|if(wp::index(env_mask,i)) {
        #|  wp::index(root_com_velocity_w,i)=wp::index(data,i);
        #|  for(int b=0;b<num_bodies;b++) wp::index(body_acc_w,i,b)=wp::spatial_vectorf(0.0f);
        #|}
      )
    "joint-position-mask" =>
      (
        #|if(!wp::index(env_mask,i)||!wp::index(user_mask,j)) continue;
        #|float value=wp::index(input_data,i,j);
        #|wp::index(user_data,i,j)=value;
        #|if(has_ordering) wp::index(backend_data,i,wp::index(user_to_backend,j))=value;
      )
    "joint-velocity-mask" =>
      (
        #|if(!wp::index(env_mask,i)||!wp::index(user_mask,j)) continue;
        #|float value=wp::index(in_data,i,j);
        #|wp::index(user_vel,i,j)=value;
        #|wp::index(user_prev_vel,i,j)=value;
        #|wp::index(user_acc,i,j)=0.0f;
        #|if(has_ordering) wp::index(backend_vel,i,wp::index(user_to_backend,j))=value;
      )
    "joint-target-mask" =>
      (
        #|if(wp::index(env_mask,i)&&wp::index(joint_mask,j)) wp::index(target,i,j)=wp::index(source,i,j);
      )
    "implicit-actuator-batch" =>
      (
        #|int joint=wp::index(joint_indices,j);
        #|float position_target=wp::index(command_pos,i,joint);
        #|float velocity_target=wp::index(command_vel,i,joint);
        #|float feedforward=wp::index(command_effort,i,joint);
        #|float effort=wp::index(joint_stiffness,i,joint)*(position_target-wp::index(joint_pos,i,joint))+wp::index(joint_damping,i,joint)*(velocity_target-wp::index(joint_vel,i,joint))+feedforward;
        #|float limit=wp::index(joint_effort_limits,i,joint);
        #|float clipped=wp::clamp(effort,-limit,limit);
        #|wp::index(batch_computed_effort,i,j)=effort;
        #|wp::index(batch_applied_effort,i,j)=clipped;
        #|wp::index(target_pos,i,joint)=position_target;
        #|wp::index(target_vel,i,joint)=velocity_target;
        #|wp::index(target_effort,i,joint)=feedforward;
        #|wp::index(computed_effort,i,joint)=effort;
        #|wp::index(applied_effort,i,joint)=clipped;
        #|wp::index(soft_velocity_limit,i,joint)=wp::index(velocity_limit,i,j);
      )
    "joint-target-reorder" =>
      (
        #|int user=wp::index(backend_to_user,j);
        #|if(write_effort||write_joint_act) {
        #|  float effort=wp::index(user_effort,i,user);
        #|  if(write_effort) wp::index(backend_effort,i,j)=effort;
        #|  if(write_joint_act) wp::index(backend_joint_act,i,j)=effort;
        #|}
        #|if(write_pos_target) wp::index(backend_pos_target,i,j)=wp::index(user_pos_target,i,user);
        #|if(write_vel_target) wp::index(backend_vel_target,i,j)=wp::index(user_vel_target,i,user);
      )
    "torque-telemetry" =>
      (
        #|int backend=j;
        #|if(sim_buffers_are_backend_order) backend=wp::index(user_to_backend,j);
        #|if(wp::index(joint_modes,j)==1) {
        #|  float err_p=wp::index(joint_pos_target,i,j)-wp::index(joint_pos_backend,i,backend);
        #|  float err_v=wp::index(joint_vel_target,i,j)-wp::index(joint_vel_backend,i,backend);
        #|  float pd=wp::index(joint_stiffness,i,j)*err_p+wp::index(joint_damping,i,j)*err_v;
        #|  float limit=wp::index(effort_limit,i,j);
        #|  float clipped=wp::clamp(pd,-limit,limit);
        #|  float total=clipped+wp::index(sim_bind_joint_effort,i,backend);
        #|  wp::index(computed,i,j)=total;
        #|  wp::index(applied,i,j)=total;
        #|} else {
        #|  wp::index(computed,i,j)=wp::index(actuator_computed_effort,i,backend);
        #|  wp::index(applied,i,j)=wp::index(sim_bind_joint_effort,i,backend);
        #|}
      )
    "publish-joint-state" =>
      (
        #|int backend=wp::index(user_to_backend,j);
        #|wp::index(user_pos,i,j)=wp::index(backend_pos,i,backend);
        #|wp::index(user_vel,i,j)=wp::index(backend_vel,i,backend);
      )
    "publish-body-state" =>
      (
        #|int backend=wp::index(user_to_backend,j);
        #|wp::index(user_pose,i,j)=wp::index(backend_pose,i,backend);
        #|wp::index(user_vel,i,j)=wp::index(backend_vel,i,backend);
      )
    "publish-joints" | "publish-body-pose" | "publish-body-velocity" =>
      (
        #|wp::index(dst,i,j)=wp::index(src,i,wp::index(dst_to_src,j));
      )
    _ => raise LowerError::Invalid("unsupported concrete kernel body")
  }
}
