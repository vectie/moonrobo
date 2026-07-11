///|
pub fn mcap_recovery_command(
  source_path : String,
  output_path : String,
  executable? : String = "mcap",
  executable_args? : Array[String] = [],
) -> Array[String] {
  let command : Array[String] = [executable]
  for arg in executable_args {
    command.push(arg)
  }
  for arg in ["recover", source_path, "-o", output_path] {
    command.push(arg)
  }
  command
}

///|
fn recovery_script(command : Array[String], log_path : String) -> String {
  let command_line = [ for arg in command => shell_quote(arg) ].join(" ")
  [
    "#!/bin/sh",
    "set -u",
    "exec >> " + shell_quote(log_path) + " 2>&1",
    "exec " + command_line,
    "",
  ].join("\n")
}

///|
fn publish_recovered_script(
  staged_path : String,
  source_path : String,
) -> String {
  [
    "#!/bin/sh",
    "set -eu",
    "mv -f " + shell_quote(staged_path) + " " + shell_quote(source_path),
    "",
  ].join("\n")
}

///|
fn write_recovery_script(
  path : String,
  body : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  @fsx.write_string_to_file(path, body) catch {
    _ =>
      return Err(
        recorder_issue(
          "write-recorder-recovery-script", path, "failed to write MoonData recorder recovery script",
        ),
      )
  }
  Ok(())
}

///|
fn replace_recovery_receipt(
  receipts : Array[RecorderRecoveryReceipt],
  replacement : RecorderRecoveryReceipt,
) -> Array[RecorderRecoveryReceipt] {
  let updated : Array[RecorderRecoveryReceipt] = []
  let mut replaced = false
  for receipt in receipts {
    if receipt.name == replacement.name {
      updated.push(replacement)
      replaced = true
    } else {
      updated.push(receipt)
    }
  }
  if !replaced {
    updated.push(replacement)
  }
  updated
}

///|
fn persist_recovery_receipt(
  session : RecorderSession,
  receipt : RecorderRecoveryReceipt,
  now_ms : Int64,
) -> Result[RecorderSession, @moondata_store.MoonDataStoreIssue] {
  let updated = {
    ..session,
    revision: session.revision + 1,
    updated_at_ms: now_ms,
    recoveries: replace_recovery_receipt(session.recoveries, receipt),
  }
  match write_recorder_session(session.plan.root, updated) {
    Ok(_) => Ok(updated)
    Err(error) => Err(error)
  }
}

///|
fn failed_recovery_receipt(
  receipt : RecorderRecoveryReceipt,
  exit_code : Int,
  message : String,
  now_ms : Int64,
) -> RecorderRecoveryReceipt {
  { ..receipt, exit_code, status: "failed", recovered_at_ms: now_ms, message }
}

///|
fn recovery_count(
  receipts : Array[RecorderRecoveryReceipt],
  status : String,
) -> Int {
  receipts.fold(init=0, fn(count, receipt) {
    if receipt.status == status {
      count + 1
    } else {
      count
    }
  })
}

///|
fn lossy_recovery_count(receipts : Array[RecorderRecoveryReceipt]) -> Int {
  receipts.fold(init=0, fn(count, receipt) {
    if receipt.status == "recovered" && receipt.lossy {
      count + 1
    } else {
      count
    }
  })
}

///|
pub fn recover_recorder_chunks(
  root : String,
  session_id : String,
  now_ms : Int64,
  executable? : String = "mcap",
  executable_args? : Array[String] = [],
) -> Result[RecorderRecoveryResult, @moondata_store.MoonDataStoreIssue] {
  let mut current = match read_recorder_session(root, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let process_may_own_chunks = current.status == "recording" ||
    current.status.has_prefix("stopping")
  if process_may_own_chunks && @native_process.is_running(current.pid) {
    return Err(
      recorder_issue(
        "recorder-session-active", session_id, "stop the recorder before recovering its MCAP chunks",
      ),
    )
  }
  let chunks = match discover_recorder_chunks(current.plan.output_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for chunk in chunks {
    if !chunk.recovery_required {
      continue
    }
    let original = match
      @moondata_blob.put_local_file(
        root,
        chunk.path,
        kind="mcap-damaged",
        content_type="application/x-mcap",
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let original_source_id = "source-" +
      session_id +
      "-" +
      recorder_chunk_token(chunk.name) +
      "-damaged-" +
      original.digest[0:12].to_owned()
    let source = @moondata_core.data_source(
      original_source_id,
      "mcap-recovery-evidence",
      "Damaged MCAP preserved before recovery",
      current.plan.robot_id,
      current.plan.bridge_id,
      "file://" + chunk.path,
      now_ms,
      source_refs=[original.data_ref],
    )
    match @moondata_store.write_source(root, source) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let running : RecorderRecoveryReceipt = {
      name: chunk.name,
      source_path: chunk.path,
      original_source_id,
      original_blob_uri: original.uri,
      original_checksum: original.data_ref.checksum,
      recovered_checksum: "",
      exit_code: -1,
      lossy: false,
      status: "running",
      recovered_at_ms: 0L,
      message: "MCAP recovery running",
    }
    current = match persist_recovery_receipt(current, running, now_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let token = recorder_chunk_token(chunk.name)
    let staged_path = chunk.path + ".recovered.next"
    if @fsx.path_exists(staged_path) {
      @fsx.remove_file(staged_path) catch {
        _ => ()
      }
    }
    let script_path = root_path(
      root,
      "runs/recorders/" + session_id + ".recover-" + token + ".sh",
    )
    let log_path = root_path(
      root,
      "logs/recorders/" + session_id + ".recover-" + token + ".log",
    )
    let command = mcap_recovery_command(
      chunk.path,
      staged_path,
      executable~,
      executable_args~,
    )
    match
      write_recovery_script(script_path, recovery_script(command, log_path)) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let code = match @native_process.run_shell_script(script_path) {
      Ok(value) => value
      Err(error) => return Err(process_issue(script_path, error))
    }
    if code != 0 && code != 3 {
      let failed = failed_recovery_receipt(
        running, code, "MCAP recovery tool failed; original bytes were preserved",
        now_ms,
      )
      current = match persist_recovery_receipt(current, failed, now_ms) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      continue
    }
    let staged = match inspect_recorder_chunk(chunk.name, staged_path) {
      Ok(value) => value
      Err(_) => {
        let failed = failed_recovery_receipt(
          running, code, "MCAP recovery did not produce a readable output file",
          now_ms,
        )
        current = match persist_recovery_receipt(current, failed, now_ms) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        continue
      }
    }
    if !staged.finalized {
      let failed = failed_recovery_receipt(
        running, code, "MCAP recovery output is not finalized", now_ms,
      )
      current = match persist_recovery_receipt(current, failed, now_ms) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      continue
    }
    let publish_path = script_path + ".publish"
    match
      write_recovery_script(
        publish_path,
        publish_recovered_script(staged_path, chunk.path),
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let publish_code = match @native_process.run_shell_script(publish_path) {
      Ok(value) => value
      Err(error) => return Err(process_issue(publish_path, error))
    }
    if publish_code != 0 {
      let failed = failed_recovery_receipt(
        running, publish_code, "validated MCAP recovery output could not replace the incoming chunk",
        now_ms,
      )
      current = match persist_recovery_receipt(current, failed, now_ms) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      continue
    }
    let recovered_checksum = match
      @moondata_blob.local_file_checksum(chunk.path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let recovered = {
      ..running,
      recovered_checksum,
      exit_code: code,
      lossy: code == 3,
      status: "recovered",
      recovered_at_ms: now_ms,
      message: if code == 3 {
        "MCAP recovered with truncated or discarded records"
      } else {
        "MCAP recovered completely"
      },
    }
    current = match persist_recovery_receipt(current, recovered, now_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  let refreshed_chunks = match
    discover_recorder_chunks(current.plan.output_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let failed_count = recovery_count(current.recoveries, "failed")
  let recovered_count = recovery_count(current.recoveries, "recovered")
  let lossy_count = lossy_recovery_count(current.recoveries)
  let recovery_remaining = refreshed_chunks.any(fn(chunk) {
    chunk.recovery_required
  })
  let status = if failed_count > 0 {
    "recovery-failed"
  } else if recovery_remaining {
    "recovery-required"
  } else if recovered_count > 0 {
    "recovered"
  } else {
    current.status
  }
  current = {
    ..current,
    status,
    revision: current.revision + 1,
    updated_at_ms: now_ms,
    chunks: refreshed_chunks,
    message: if status == "recovered" {
      "all recoverable MCAP chunks were restored and are ready to seal"
    } else if status == "recovery-failed" {
      "one or more MCAP chunks could not be recovered"
    } else {
      current.message
    },
  }
  match write_recorder_session(root, current) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_index.rebuild_catalog(root, now_ms) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok({
    schema_version: "moondata.recorder-recovery.v1",
    session: current,
    recovered_count,
    lossy_count,
    failed_count,
  })
}

///|
pub fn finalize_recorder_session(
  root : String,
  session_id : String,
  now_ms : Int64,
  executable? : String = "mcap",
  executable_args? : Array[String] = [],
) -> Result[RecorderFinalizeResult, @moondata_store.MoonDataStoreIssue] {
  let recovery = match
    recover_recorder_chunks(
      root,
      session_id,
      now_ms,
      executable~,
      executable_args~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if recovery.failed_count > 0 {
    return Ok({
      schema_version: "moondata.recorder-finalize.v1",
      status: "recovery-failed",
      ready: false,
      recovery,
      promotion: None,
    })
  }
  if recovery.session.chunks.any(fn(chunk) { chunk.recovery_required }) {
    return Ok({
      schema_version: "moondata.recorder-finalize.v1",
      status: "recovery-required",
      ready: false,
      recovery,
      promotion: None,
    })
  }
  let promotion = match seal_recorder_chunks(root, session_id, now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let ready = promotion.sealed_count > 0 &&
    promotion.recovery_required_count == 0 &&
    promotion.invalid_count == 0
  Ok({
    schema_version: "moondata.recorder-finalize.v1",
    status: if ready {
      "sealed"
    } else {
      promotion.session.status
    },
    ready,
    recovery,
    promotion: Some(promotion),
  })
}
