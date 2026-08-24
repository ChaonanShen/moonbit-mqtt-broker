///|
pub(all) enum LogLevel {
  Error
  Warn
  Info
  Debug
} derive(Eq, Debug)

///|
pub(all) enum LogFormat {
  Text
  Json
} derive(Eq, Debug)

///|
pub struct LogRecord {
  timestamp_ms : Int64
  level : LogLevel
  event : String
  message : String
  connection_id : String
  client_id : String
  principal : String
  peer : String
  reason : String
  snapshot_revision : String
}

///|
pub fn LogRecord::new(
  timestamp_ms : Int64,
  level : LogLevel,
  event : String,
  message? : String = "",
  connection_id? : String = "",
  client_id? : String = "",
  principal? : String = "",
  peer? : String = "",
  reason? : String = "",
  snapshot_revision? : String = "",
) -> LogRecord {
  {
    timestamp_ms,
    level,
    event,
    message,
    connection_id,
    client_id,
    principal,
    peer,
    reason,
    snapshot_revision,
  }
}

///|
pub struct Logger {
  minimum_level : LogLevel
  format : LogFormat
  output_enabled : Bool
}

///|
pub fn Logger::new(
  minimum_level? : LogLevel = Info,
  format? : LogFormat = Text,
) -> Logger {
  { minimum_level, format, output_enabled: true }
}

///|
pub fn Logger::silent() -> Logger {
  { minimum_level: Error, format: Text, output_enabled: false }
}

///|
fn level_rank(level : LogLevel) -> Int {
  match level {
    Error => 0
    Warn => 1
    Info => 2
    Debug => 3
  }
}

///|
fn level_name(level : LogLevel) -> String {
  match level {
    Error => "error"
    Warn => "warn"
    Info => "info"
    Debug => "debug"
  }
}

///|
pub fn Logger::enabled(self : Logger, level : LogLevel) -> Bool {
  self.output_enabled && level_rank(level) <= level_rank(self.minimum_level)
}

///|
pub fn Logger::render(self : Logger, record : LogRecord) -> String? {
  if !self.enabled(record.level) {
    return None
  }
  match self.format {
    Text => {
      let mut line = "timestamp_ms=" +
        record.timestamp_ms.to_string() +
        " level=" +
        level_name(record.level) +
        " event=" +
        record.event
      if record.message != "" {
        line = line + " message=" + record.message
      }
      if record.connection_id != "" {
        line = line + " connection_id=" + record.connection_id
      }
      if record.client_id != "" {
        line = line + " client_id=" + record.client_id
      }
      if record.principal != "" {
        line = line + " principal=" + record.principal
      }
      if record.peer != "" {
        line = line + " peer=" + record.peer
      }
      if record.reason != "" {
        line = line + " reason=" + record.reason
      }
      if record.snapshot_revision != "" {
        line = line + " snapshot_revision=" + record.snapshot_revision
      }
      Some(line)
    }
    Json => {
      let fields : Map[String, String] = Map([
        ("timestamp_ms", record.timestamp_ms.to_string()),
        ("level", level_name(record.level)),
        ("event", record.event),
        ("message", record.message),
        ("connection_id", record.connection_id),
        ("client_id", record.client_id),
        ("principal", record.principal),
        ("peer", record.peer),
        ("reason", record.reason),
        ("snapshot_revision", record.snapshot_revision),
      ])
      Some(@json.to_json(fields).stringify())
    }
  }
}

///|
pub fn Logger::log(self : Logger, record : LogRecord) -> Unit {
  match self.render(record) {
    Some(line) => println(line)
    None => ()
  }
}
