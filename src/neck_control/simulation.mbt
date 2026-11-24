///|
priv struct SimBus {
  registers : Map[Int32, FixedArray[Byte]]
  writes : Array[(Int32, Array[Byte])]
  events : Array[String]
  mut clock : Int64
  fail_audit : Bool
  audit_delay_ms : Int32
  fail_reply_after_write : Int32
  reset_inactive_after_write : Int32
}

///|
fn SimBus::new(
  fail_audit~ : Bool = false,
  audit_delay_ms~ : Int32 = 0,
  fail_reply_after_write~ : Int32 = -1,
  reset_inactive_after_write~ : Int32 = -1,
) -> SimBus {
  let registers = Map([])
  for
    (id, minimum, maximum, offset) in [
      (7, 933, 3043, 3948),
      (8, 1040, 3204, 1882),
    ] {
    let bytes : FixedArray[Byte] = FixedArray::make(128, 0)
    bytes[0] = 3
    bytes[1] = 10
    bytes[3] = 9
    bytes[4] = 3
    bytes[5] = id.to_byte()
    bytes[18] = 12
    bytes[30] = 1
    bytes[33] = 0
    bytes[62] = 123
    bytes[63] = 30
    for
      (address, value) in [
        (9, minimum),
        (11, maximum),
        (31, offset),
        (48, 1000),
        (56, if id == 7 { 1927 } else { 2047 }),
      ] {
      bytes[address] = (value & 255).to_byte()
      bytes[address + 1] = (value >> 8).to_byte()
    }
    registers[id] = bytes
  }
  {
    registers,
    writes: [],
    events: [],
    clock: 1000L,
    fail_audit,
    audit_delay_ms,
    fail_reply_after_write,
    reset_inactive_after_write,
  }
}

///|
impl Bus for SimBus with fn now(self) {
  self.clock
}

///|
impl Bus for SimBus with fn wait(self, ms) {
  self.clock += ms.to_int64()
}

///|
impl Bus for SimBus with fn event(self, name, _) {
  if self.fail_audit {
    raise Transport("Simulated full audit disk")
  }
  self.events.push(name)
  if name == "authorized-write" {
    self.clock += self.audit_delay_ms.to_int64()
  }
}

///|
impl Bus for SimBus with fn transfer(
  self,
  id,
  instruction,
  params,
  count,
  expires_at,
) {
  self.clock += 1L
  self.event("tx-before-send", Json("simulation"))
  guard expires_at == 0L || self.clock <= expires_at else {
    raise Rejected("Simulated expired dispatch")
  }
  let registers = self.registers[id]
  if instruction == 2 {
    let address = params[0].to_int()
    Bytes::from_array(Array::makei(count, i => registers[address + i]))
  } else {
    let address = params[0].to_int()
    self.writes.push((id, params.copy()))
    for i in 1..<params.length() {
      registers[address + i - 1] = params[i]
    }
    if address == 42 {
      // Emulate the exact hazardous device behavior: every goal re-energizes,
      // regardless of the previous torque flag. The policy must handle this.
      registers[40] = 1
      registers[56] = registers[42]
      registers[57] = registers[43]
    }
    if self.writes.length() == self.fail_reply_after_write {
      raise Transport("Simulated applied write with lost acknowledgement")
    }
    if self.writes.length() == self.reset_inactive_after_write {
      self.registers[8][40] = 0
      self.registers[8][46] = 0
    }
    b""
  }
}

///|
pub(all) struct Simulation {
  simulated : Bool
  report : Report
  writes : Array[Json]
} derive(Debug, ToJson)

///|
pub fn simulate(action : Action) -> Simulation raise {
  let bus = SimBus::new()
  let report = run_action(bus, action)
  {
    simulated: true,
    report,
    writes: bus.writes.map(w => {
      (
        {
          "id": Json(w.0),
          "parameters": Json(w.1.map(b => b.to_int())),
          "packet_hex": Json(@hex.encode(request_packet(w.0, 3, w.1))),
        } : Json)
    }),
  }
}
