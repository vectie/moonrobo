///|
fn fixture() -> String raise {
  @fs.read_file_to_string(
    "src/spatial_import/testdata/engineering.portable.json",
  )
}

///|
fn ingest(
  text : String,
  parent? : String = "sha256:15e7a26f57448cbc8ef67eb87803bd8f7f8acf14ae6cd0f2f03a6723b1dceda7",
) -> Result[EngineeringSpatialInput, EngineeringImportIssue] {
  ingest_moonmold_engineering(text, expected_editable_parent_digest=parent)
}

///|
test "MoonRobo accepts engineering candidate without upgrading its claim" {
  match ingest(fixture()) {
    Ok(value) => {
      assert_eq(value.artifact_id, "arched-lunar-habitat:engineering-model")
      assert_eq(value.units, "mm")
      assert_false(value.qualification_claimed)
      assert_true(value.unresolved_gaps.length() == 3)
    }
    Err(problem) => fail("unexpected rejection: \{problem.code}")
  }
}

///|
test "MoonRobo rejects styled and manufacturing representations" {
  let base = fixture()
  for lane in ["visual-styled-model", "manufacturing-candidate"] {
    let candidate = base
      .replace(
        old="\"representation\":\"engineering-model\"",
        new="\"representation\":\"\{lane}\"",
      )
      .replace(
        old="\"child_representation\":\"engineering-model\"",
        new="\"child_representation\":\"\{lane}\"",
      )
    match ingest(candidate) {
      Err(problem) => assert_eq(problem.code, "wrong-engineering-lane")
      Ok(_) => fail("expected lane rejection")
    }
  }
}

///|
test "MoonRobo rejects stale, lossy, and elevated-claim engineering" {
  match
    ingest(
      fixture(),
      parent="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ) {
    Err(problem) => assert_eq(problem.code, "stale-editable-parent")
    Ok(_) => fail("expected stale rejection")
  }
  let lossy = fixture().replace(
    old="\"declared_losses\":[]",
    new="\"declared_losses\":[\"style simplification\"]",
  )
  match ingest(lossy) {
    Err(problem) => assert_eq(problem.code, "lossy-engineering-input")
    Ok(_) => fail("expected loss rejection")
  }
  let elevated = fixture().replace(
    old="\"claim_ceiling\":\"digital-artifact\"",
    new="\"claim_ceiling\":\"physical-readiness\"",
  )
  match ingest(elevated) {
    Err(problem) => assert_eq(problem.code, "claim-ceiling-exceeded")
    Ok(_) => fail("expected claim rejection")
  }
}
