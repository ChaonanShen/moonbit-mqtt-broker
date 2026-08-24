///|
pub(all) enum AccessKind {
  Read
  Write
} derive(Eq, Debug)

///|
pub(all) enum AclFileError {
  InvalidLine(Int)
  MissingPrincipal(Int)
  InvalidPrincipal(Int)
  InvalidAccess(Int)
  InvalidFilter(Int)
} derive(Eq, Debug)

///|
struct AclRule {
  principal : Principal
  access : AccessKind
  filter : @topic.TopicFilter
}

///|
pub struct AclPolicy {
  rules : Array[AclRule]
}

///|
fn split_acl_fields(line : StringView) -> Array[String] {
  line
  .split(" ")
  .to_array()
  .filter(field => field != "")
  .map(field => field.to_owned())
}

///|
pub fn AclPolicy::parse(contents : String) -> Result[AclPolicy, AclFileError] {
  let rules : Array[AclRule] = []
  let mut principal : Principal? = None
  let lines = contents.replace_all(old="\r\n", new="\n").split("\n").to_array()
  for index in 0..<lines.length() {
    let trimmed = lines[index].trim()
    if trimmed == "" || trimmed.has_prefix("#") {
      continue
    }
    let fields = split_acl_fields(trimmed)
    match fields {
      ["user", username] => {
        if username == "anonymous" || username == "legacy-anonymous" {
          return Err(InvalidPrincipal(index + 1))
        }
        principal = Some(User(username))
      }
      ["anonymous"] => principal = Some(Anonymous)
      ["topic", access_value, filter_value] => {
        let owner = match principal {
          None => return Err(MissingPrincipal(index + 1))
          Some(value) => value
        }
        let access_values : Array[AccessKind] = match access_value {
          "read" => [Read]
          "write" => [Write]
          "readwrite" => [Read, Write]
          _ => return Err(InvalidAccess(index + 1))
        }
        let filter = match @topic.TopicFilter::new(filter_value) {
          Ok(value) => value
          Err(_) => return Err(InvalidFilter(index + 1))
        }
        for access in access_values {
          rules.push({ principal: owner, access, filter })
        }
      }
      _ => return Err(InvalidLine(index + 1))
    }
  }
  Ok({ rules, })
}

///|
fn filter_contains(
  allowed : @topic.TopicFilter,
  requested : @topic.TopicFilter,
) -> Bool {
  let allowed_levels = allowed.value().split("/").to_array()
  let requested_levels = requested.value().split("/").to_array()
  if requested_levels[0].has_prefix("$") &&
    (allowed_levels[0] == "+" || allowed_levels[0] == "#") {
    return false
  }
  let mut index = 0
  for ;; {
    if index >= allowed_levels.length() {
      return index >= requested_levels.length()
    }
    let allowed_level = allowed_levels[index]
    if allowed_level == "#" {
      return true
    }
    if index >= requested_levels.length() {
      return false
    }
    let requested_level = requested_levels[index]
    if requested_level == "#" {
      return false
    }
    if requested_level == "+" {
      if allowed_level != "+" {
        return false
      }
    } else if allowed_level != "+" && allowed_level != requested_level {
      return false
    }
    index = index + 1
  }
}

///|
pub fn AclPolicy::can_read_filter(
  self : AclPolicy,
  principal : Principal,
  requested : @topic.TopicFilter,
) -> Bool {
  self.rules.any(rule => {
    rule.principal == principal &&
    rule.access == Read &&
    filter_contains(rule.filter, requested)
  })
}

///|
pub fn AclPolicy::can_read_topic(
  self : AclPolicy,
  principal : Principal,
  topic : @topic.TopicName,
) -> Bool {
  self.rules.any(rule => {
    rule.principal == principal &&
    rule.access == Read &&
    rule.filter.matches(topic)
  })
}

///|
pub fn AclPolicy::can_write_topic(
  self : AclPolicy,
  principal : Principal,
  topic : @topic.TopicName,
) -> Bool {
  if topic.value().has_prefix("$SYS/") || topic.value() == "$SYS" {
    return false
  }
  self.rules.any(rule => {
    rule.principal == principal &&
    rule.access == Write &&
    rule.filter.matches(topic)
  })
}
