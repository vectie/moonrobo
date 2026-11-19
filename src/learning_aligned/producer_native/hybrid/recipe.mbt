///|
fn object_field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(found) else {
    fail("native scene recipe is missing field: " + name)
  }
  found
}

///|
fn recipe_field(
  recipe : Json?,
  section : String,
  name : String,
  fallback : Json,
) -> Json raise {
  match recipe {
    None => fallback
    Some(value) => object_field(object_field(value, section), name)
  }
}

///|
fn recipe_entry(
  recipe : Json?,
  name : String,
  index : Int32,
  joint : String,
) -> Json? raise {
  match recipe {
    None => None
    Some(value) => {
      guard object_field(value, name) is Array(items) &&
        items.length() == 29 &&
        items.get(index) is Some(item) &&
        object_field(item, "name") == joint.to_json() else {
        fail("native scene recipe does not preserve canonical joint order")
      }
      Some(item)
    }
  }
}

///|
fn entry_field(entry : Json?, name : String, fallback : Json) -> Json raise {
  match entry {
    None => fallback
    Some(value) => object_field(value, name)
  }
}
