///|
priv struct Configuration {
  format : String
  catalog_id : String
  skills : Array[@skills.Skill]
  joint_calibration : @policy.Calibration
  imu_calibration : @policy.ImuCalibration
  references : Array[String]
  maximum_sensor_age_ms : Int64
} derive(FromJson)

///|
/// Read-only SDK shadow preparation. The selected actor remains borrowed until
/// its host and cleanup return. This owner records command frames and never
/// supplies Controller::publish as the runner's output callback.
pub struct Plan {
  priv actor : @actor.Actor
  priv supervisor : @skills.Supervisor
  priv calibration : @policy.Calibration
  priv imu : @policy.Imu
  priv clips : Map[String, @reference.Clip]
  priv maximum_age : Int64
}

///|
/// Load explicit local configuration/reference files before opening the SDK.
/// Reference paths are used as written, relative to the process working dir.
pub async fn Plan::read(actor : @actor.Actor, path : String) -> Self {
  let configuration : Configuration = @json.from_json(
    @fs.read_file(path).json(),
  )
  guard configuration.format == "moonrobo.e1-sdk-shadow.v1" &&
    actor.bundle().observation_width() == 99 &&
    configuration.joint_calibration.profile_id == actor.bundle().profile_id() &&
    configuration.maximum_sensor_age_ms >= 0L else {
    fail("E1 SDK shadow configuration or actor profile differs")
  }
  let supervisor = @skills.Supervisor::new(
    configuration.catalog_id,
    configuration.skills,
  )
  let imu = @policy.Imu::new(configuration.imu_calibration)
  let clips : Map[String, @reference.Clip] = Map([])
  for path in configuration.references {
    let clip = @reference.Clip::read(actor.bundle(), path)
    guard !clips.contains(clip.reference_id()) else {
      fail("duplicate SDK shadow reference")
    }
    clips[clip.reference_id()] = clip
  }
  for skill in configuration.skills {
    guard skill.parameters.is_empty() && clips.contains(skill.reference_id) else {
      fail(
        "SDK shadow skills require prepared references and no parameter transforms",
      )
    }
  }
  {
    actor,
    supervisor,
    calibration: configuration.joint_calibration,
    imu,
    clips,
    maximum_age: configuration.maximum_sensor_age_ms,
  }
}

///|
/// Bind an explicitly opened, borrowed controller. The host only records mapped
/// commands; it initializes no SDK, publishes no command and defines no physical
/// stop. A record failure propagates through the existing runner/host cleanup.
pub fn Plan::host(
  self : Self,
  controller : @low.Controller,
  clock~ : () -> Int64,
  record~ : (Json) -> Unit raise,
  stopped~ : () -> Unit,
) -> @host.Host raise {
  let mapping = @policy.Mapping::new(self.actor.bundle(), self.calibration, resolve=name => {
    controller.joint_index(name)
  })
  let observer = @policy.Observer::new(mapping, self.imu)
  @host.Host::new(self.supervisor, clock~, prepare=(owner, clock) => {
    let sensor = @control.Sensor::from_sdk(controller, observer, clock~)
    @control.new_runner(
      owner,
      self.actor,
      mapping,
      sensor,
      maximum_sensor_age_ms=self.maximum_age,
      reference=(execution, step, _) => {
        guard self.clips.get(execution.reference_id) is Some(clip) else {
          fail("unknown SDK shadow reference")
        }
        let frame = clip.frame(execution, step)
        {
          goals: frame.goals,
          body_to_world: frame.body_to_world,
          complete: frame.complete,
        }
      },
      publish=commands => {
        let value : Json = {
          "format": "moonrobo.e1-sdk-shadow-tick.v1",
          "published": false,
          "hardware_qualified": false,
          "recorded_at_ms": Json(clock()),
          "commands": Json(
            Array::makei(commands.length(), slot => {
              let command = commands[slot]
              let row : Json = {
                "slot": slot,
                "position": command.position,
                "velocity": command.velocity,
                "torque": command.torque,
                "kp": command.kp,
                "kd": command.kd,
              }
              row
            }),
          ),
        }
        record(value)
      },
      stop=stopped,
    )
  })
}
