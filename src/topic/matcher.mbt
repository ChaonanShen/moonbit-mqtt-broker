///|
pub fn TopicFilter::matches(self : TopicFilter, topic : TopicName) -> Bool {
  let filter_levels = self.value.split("/").to_array()
  let topic_levels = topic.value.split("/").to_array()
  // MQTT reserves $-prefixed topic names from root wildcard subscriptions.
  if topic.value.has_prefix("$") &&
    (filter_levels[0] == "+" || filter_levels[0] == "#") {
    return false
  }
  let mut topic_index = 0
  for filter_index in 0..<filter_levels.length() {
    let filter_level = filter_levels[filter_index]
    if filter_level == "#" {
      return true
    }
    if topic_index >= topic_levels.length() {
      return false
    }
    if filter_level != "+" && filter_level != topic_levels[topic_index] {
      return false
    }
    topic_index = topic_index + 1
  }
  topic_index == topic_levels.length()
}
