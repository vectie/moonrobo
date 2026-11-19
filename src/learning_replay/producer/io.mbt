///|
fn field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(result) else {
    fail("missing replay source field: " + name)
  }
  result
}

///|
fn text(value : Json) -> String raise {
  guard value is String(result) else { fail("expected replay source string") }
  result
}

///|
fn array(value : Json) -> Array[Json] raise {
  guard value is Array(result) else { fail("expected replay source array") }
  result
}

///|
fn number(value : Json) -> Double raise {
  guard value is Number(result, ..) && !result.is_nan() && !result.is_inf() else {
    fail("expected finite replay source number")
  }
  result
}

///|
fn integer(value : Json) -> Int32 raise {
  let x = number(value)
  guard x >= 0 && x <= 2147483647 && x.to_int().to_double() == x else {
    fail("expected nonnegative replay source integer")
  }
  x.to_int()
}

///|
fn matrix(
  arrays : Map[String, @artifacts.NumericArray],
  name : String,
) -> Array[Array[Double]] raise {
  guard arrays.get(name) is Some(values) && values.shape.length() == 2 else {
    fail("missing replay matrix " + name)
  }
  let rows = values.shape[0]
  let width = values.shape[1]
  guard rows > 0 &&
    width > 0 &&
    width <= 16384 &&
    rows <= 100000 &&
    values.values.length() == rows * width &&
    values.values.all(x => !x.is_nan() && !x.is_inf()) else {
    fail("invalid replay matrix shape or numbers " + name)
  }
  Array::makei(rows, i => values.values[i * width:(i + 1) * width].to_owned())
}

///|
fn parent(path : String) -> String {
  let parts = path.split("/").collect()
  if parts.length() <= 1 {
    return "."
  }
  parts[:parts.length() - 1].map(part => part.to_owned()).join("/")
}

///|
fn source_path(folder : String, path : String) -> String raise {
  guard !path.is_empty() &&
    !path.contains("\\") &&
    !path.split("/").any(part => part == "..") else {
    fail("unsafe replay source path")
  }
  if path.has_prefix("/") {
    path
  } else {
    folder + "/" + path
  }
}

///|
fn strings(value : Json) -> Array[String] raise {
  let result : Array[String] = []
  for item in array(value) {
    result.push(text(item))
  }
  result
}

///|
fn records_from_study(
  study : Json,
  seed : Int32?,
) -> Array[(Json, String)] raise {
  let records : Array[(Json, String)] = []
  if study is { "physical_records": Array(values), .. } {
    for record in values {
      if seed is Some(wanted) {
        guard record is { "seed": actual, .. } else {
          fail("physical record lacks seed")
        }
        if integer(actual) != wanted {
          continue
        }
      }
      let label = if record is { "role": String(role), .. } {
        role
      } else {
        "physics"
      }
      records.push((record, label))
    }
  } else if study is { "evaluations": Array(evaluations), .. } {
    for evaluation in evaluations {
      let label = text(field(evaluation, "label"))
      if seed is Some(wanted) && label != "seed-\{wanted}" {
        continue
      }
      for record in array(field(evaluation, "records")) {
        records.push((record, label))
      }
    }
  } else {
    fail("study has no full recorded physical trajectories")
  }
  records
}
