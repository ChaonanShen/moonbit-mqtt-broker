///|
pub(all) enum ManagementRoute {
  RouteLive
  RouteReady
  RouteMetrics
  RouteStatus
} derive(Eq)

///|
/// One service-wide request/accept limiter, independent of MQTT rate switches.
pub struct ManagementHttp {
  config : @management.ManagementConfig
  tokens : @management.TokenDatabase
  cache : @management.ObservationCache
  budget : @management.ManagementBudget
  rejections : @management.ManagementRejections
  connection_bucket : @budget.Bucket
  request_bucket : @budget.Bucket
  boot_id : String
  mut query_mailbox : ManagementQueryMailbox?
  mut command_mailbox : ManagementCommandMailbox?
  mut reload_generation : GenerationHandle?
  command_bucket : @budget.Bucket
  availability : ManagementAvailability?
  mut next_request_id : Int64
}

///|
pub fn ManagementHttp::new(
  config : @management.ManagementConfig,
  tokens : @management.TokenDatabase,
  cache : @management.ObservationCache,
  budget : @management.ManagementBudget,
  rejections : @management.ManagementRejections,
  boot_id : String,
  now_monotonic_ms : Int64,
  query_mailbox? : ManagementQueryMailbox,
  command_mailbox? : ManagementCommandMailbox,
  availability? : ManagementAvailability,
) -> Result[ManagementHttp, @budget.BudgetError] {
  if !config.enabled() {
    return Err(@budget.InvalidConfiguration)
  }
  let connection_bucket = match
    @budget.Bucket::new(
      config.connection_rate().to_int64(),
      config.connection_burst().to_int64(),
      now_monotonic_ms,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let request_bucket = match
    @budget.Bucket::new(
      config.request_rate().to_int64(),
      config.request_burst().to_int64(),
      now_monotonic_ms,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let command_bucket = match
    @budget.Bucket::new(
      config.command_rate().to_int64(),
      config.command_burst().to_int64(),
      now_monotonic_ms,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    config,
    tokens,
    cache,
    budget,
    rejections,
    connection_bucket,
    request_bucket,
    boot_id,
    query_mailbox,
    command_mailbox,
    reload_generation: None,
    command_bucket,
    availability,
    next_request_id: 1L,
  })
}

///|
fn ManagementHttp::request_id(self : ManagementHttp) -> String? {
  if self.next_request_id <= 0L || self.next_request_id == 9223372036854775807L {
    return None
  }
  let id = self.boot_id + "." + self.next_request_id.to_string()
  self.next_request_id += 1L
  Some(id)
}

///|
pub fn ManagementHttp::admit_connection(
  self : ManagementHttp,
  now_monotonic_ms : Int64,
) -> Bool {
  if now_monotonic_ms < 0L {
    self.rejections.record(@management.RejectedStale)
    return false
  }
  if @budget.admit([(self.connection_bucket, 1L)], now_monotonic_ms) is Err(_) {
    self.rejections.record(@management.RejectedRate)
    false
  } else {
    true
  }
}

///|
fn management_error_body(code : String, request_id : String) -> Bytes {
  let detail : Map[String, String] = Map([
    ("code", code),
    ("message", code),
    ("request_id", request_id),
  ])
  let body : Map[String, Json] = Map([("error", @json.to_json(detail))])
  @utf8.encode(@json.to_json(body).stringify())
}

///|
fn ManagementHttp::encode(
  self : ManagementHttp,
  status : @http_transport.HttpStatus,
  body : Bytes,
  body_type : @http_transport.HttpBodyType,
  allow? : @http_transport.HttpAllow,
  location? : String,
  etag? : String,
) -> Bytes {
  match
    @http_transport.encode_response(
      status,
      body_type,
      body,
      self.config.max_response_bytes(),
      allow?,
      location?,
      etag?,
    ) {
    Ok(value) => value
    Err(_) =>
      @http_transport.encode_response(
        @http_transport.ServiceUnavailable,
        @http_transport.JsonBody,
        b"{\"error\":{\"code\":\"unavailable\"}}",
        self.config.max_response_bytes(),
      ).unwrap()
  }
}

///|
fn ManagementHttp::reject(
  self : ManagementHttp,
  status : @http_transport.HttpStatus,
  code : String,
  request_id : String,
  reason : @management.ManagementRejectReason,
  allow? : @http_transport.HttpAllow,
) -> Bytes {
  self.rejections.record(reason)
  self.encode(
    status,
    management_error_body(code, request_id),
    @http_transport.JsonBody,
    allow?,
  )
}

///|
fn management_header(
  head : @http_transport.HttpRequestHead,
  name : String,
) -> String? {
  for header in head.headers {
    if header.name == name {
      return Some(header.value)
    }
  }
  None
}

///|
fn management_bearer(value : String) -> String? {
  if value.length() < 8 || value[6].to_int() != 32 {
    return None
  }
  let prefix = value[:6].to_owned()
  let letters = "bearer"
  for index in 0..<6 {
    let unit = prefix[index].to_int()
    let lowered = if unit >= 65 && unit <= 90 { unit + 32 } else { unit }
    if lowered != letters[index].to_int() {
      return None
    }
  }
  Some(value[7:].to_owned())
}

///|
/// Route on already parsed, bounded head data. No broker state or message
/// payload can be reached from this function.
pub fn ManagementHttp::respond(
  self : ManagementHttp,
  head : @http_transport.HttpRequestHead,
  same_read_suffix_bytes : Int,
  now_monotonic_ms : Int64,
) -> Bytes {
  let request_id = match self.request_id() {
    Some(value) => value
    None =>
      return self.encode(
        @http_transport.ServiceUnavailable,
        b"{\"error\":{\"code\":\"id_exhausted\"}}",
        @http_transport.JsonBody,
      )
  }
  let target = head.target
  if target.contains("?") ||
    target.contains("%") ||
    target.contains("#") ||
    same_read_suffix_bytes != 0 ||
    (head.content_length is Some(length) && length != 0) {
    return self.reject(
      @http_transport.BadRequest,
      "bad_request",
      request_id,
      @management.RejectedParse,
    )
  }
  for forbidden in ["transfer-encoding", "upgrade", "expect"] {
    if management_header(head, forbidden) is Some(_) {
      return self.reject(
        @http_transport.BadRequest,
        "bad_request",
        request_id,
        @management.RejectedParse,
      )
    }
  }
  let route = match target {
    "/health/live" => Some(RouteLive)
    "/health/ready" => Some(RouteReady)
    "/metrics" => Some(RouteMetrics)
    "/v1/status" => Some(RouteStatus)
    _ => None
  }
  let route = match route {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.NotFound,
        "not_found",
        request_id,
        @management.RejectedOther,
      )
  }
  if head.method_name != "GET" {
    return self.reject(
      @http_transport.MethodNotAllowed,
      "method_not_allowed",
      request_id,
      @management.RejectedParse,
      allow=@http_transport.AllowGet,
    )
  }
  if now_monotonic_ms < 0L {
    return self.reject(
      @http_transport.ServiceUnavailable,
      "unavailable",
      request_id,
      @management.RejectedStale,
    )
  }
  if @budget.admit([(self.request_bucket, 1L)], now_monotonic_ms) is Err(_) {
    return self.reject(
      @http_transport.TooManyRequests,
      "rate_limited",
      request_id,
      @management.RejectedRate,
    )
  }
  if route == RouteLive || route == RouteReady {
    let decision = match self.cache.health(now_monotonic_ms) {
      Ok(value) => value
      Err(_) =>
        return self.reject(
          @http_transport.ServiceUnavailable,
          "unavailable",
          request_id,
          @management.RejectedStale,
        )
    }
    let healthy = if route == RouteLive {
      decision.live
    } else {
      decision.ready
    }
    return self.encode(
      if healthy {
        @http_transport.Ok
      } else {
        @http_transport.ServiceUnavailable
      },
      if route == RouteLive {
        @management.encode_health_live(decision)
      } else {
        @management.encode_health_ready(decision)
      },
      @http_transport.JsonBody,
    )
  }
  let token = match management_header(head, "authorization") {
    Some(value) => management_bearer(value)
    None => None
  }
  let actor = match token {
    Some(value) => self.tokens.authenticate(value)
    None => None
  }
  let actor = match actor {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.Unauthorized,
        "unauthenticated",
        request_id,
        @management.RejectedAuth,
      )
  }
  let needed = if route == RouteMetrics {
    @management.Metrics
  } else {
    @management.Read
  }
  if !actor.allows(needed) {
    return self.reject(
      @http_transport.Forbidden,
      "forbidden",
      request_id,
      @management.RejectedRole,
    )
  }
  let body = if route == RouteMetrics {
    self.cache.render_metrics(now_monotonic_ms, self.rejections)
  } else {
    self.cache.status_body(
      now_monotonic_ms,
      details_enabled=self.config.details_enabled(),
      operations_enabled=self.config.operations_enabled(),
      details_available=self.availability is Some(value) &&
        value.details_available,
    )
  }
  match body {
    Ok(value) =>
      self.encode(
        @http_transport.Ok,
        value,
        if route == RouteMetrics {
          @http_transport.PrometheusBody
        } else {
          @http_transport.JsonBody
        },
      )
    Err(_) =>
      self.reject(
        @http_transport.ServiceUnavailable,
        "stale",
        request_id,
        @management.RejectedStale,
      )
  }
}

///|
/// B details use a typed bounded mailbox. The HTTP coroutine never touches
/// BrokerState or borrows a mutable Session across an await.
pub async fn ManagementHttp::respond_details(
  self : ManagementHttp,
  head : @http_transport.HttpRequestHead,
  same_read_suffix_bytes : Int,
  now_monotonic_ms : Int64,
) -> Bytes {
  let request_id = match self.request_id() {
    Some(value) => value
    None =>
      return self.encode(
        @http_transport.ServiceUnavailable,
        b"{\"error\":{\"code\":\"id_exhausted\"}}",
        @http_transport.JsonBody,
      )
  }
  if head.target.contains("%") ||
    head.target.contains("#") ||
    same_read_suffix_bytes != 0 ||
    (head.content_length is Some(length) && length != 0) {
    return self.reject(
      @http_transport.BadRequest,
      "bad_request",
      request_id,
      @management.RejectedParse,
    )
  }
  for forbidden in ["transfer-encoding", "upgrade", "expect"] {
    if management_header(head, forbidden) is Some(_) {
      return self.reject(
        @http_transport.BadRequest,
        "bad_request",
        request_id,
        @management.RejectedParse,
      )
    }
  }
  if head.method_name != "GET" {
    return self.reject(
      @http_transport.MethodNotAllowed,
      "method_not_allowed",
      request_id,
      @management.RejectedParse,
      allow=@http_transport.AllowGet,
    )
  }
  if now_monotonic_ms < 0L {
    return self.reject(
      @http_transport.ServiceUnavailable,
      "unavailable",
      request_id,
      @management.RejectedStale,
    )
  }
  if @budget.admit([(self.request_bucket, 1L)], now_monotonic_ms) is Err(_) {
    return self.reject(
      @http_transport.TooManyRequests,
      "rate_limited",
      request_id,
      @management.RejectedRate,
    )
  }
  let token = match management_header(head, "authorization") {
    Some(value) => management_bearer(value)
    None => None
  }
  let actor = match token {
    Some(value) => self.tokens.authenticate(value)
    None => None
  }
  let actor = match actor {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.Unauthorized,
        "unauthenticated",
        request_id,
        @management.RejectedAuth,
      )
  }
  if !actor.allows(@management.Read) {
    return self.reject(
      @http_transport.Forbidden,
      "forbidden",
      request_id,
      @management.RejectedRole,
    )
  }
  let spec = match
    @management.parse_read_query(
      head.target,
      actor.token_id(),
      self.config.default_page_size(),
      self.config.max_page_size(),
    ) {
    Ok(value) => value
    Err(@management.QueryNotFound) =>
      return self.reject(
        @http_transport.NotFound,
        "not_found",
        request_id,
        @management.RejectedOther,
      )
    Err(_) =>
      return self.reject(
        @http_transport.BadRequest,
        "bad_request",
        request_id,
        @management.RejectedParse,
      )
  }
  if !self.config.details_enabled() {
    return self.reject(
      @http_transport.ServiceUnavailable,
      "details_disabled",
      request_id,
      @management.RejectedOther,
    )
  }
  let mailbox = match self.query_mailbox {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.ServiceUnavailable,
        "details_unavailable",
        request_id,
        @management.RejectedOther,
      )
  }
  let ticket = match mailbox.submit(spec) {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.TooManyRequests,
        "capacity_exhausted",
        request_id,
        @management.RejectedCapacity,
      )
  }
  defer mailbox.release(ticket)
  let reply = @async.with_timeout_opt(self.config.query_timeout_ms(), () => {
    mailbox.wait(ticket)
  }) catch {
    _ => None
  }
  let reply = match reply {
    Some(Some(value)) => value
    _ =>
      return self.reject(
        @http_transport.ServiceUnavailable,
        "unavailable",
        request_id,
        @management.RejectedDeadline,
      )
  }
  self.encode(reply.status, reply.body, @http_transport.JsonBody)
}

///|
pub async fn ManagementHttp::respond_command(
  self : ManagementHttp,
  head : @http_transport.HttpRequestHead,
  same_read_suffix_bytes : Int,
  now_monotonic_ms : Int64,
  body? : Bytes,
) -> Bytes {
  let request_id = match self.request_id() {
    Some(value) => value
    None =>
      return self.encode(
        @http_transport.ServiceUnavailable,
        b"{\"error\":{\"code\":\"id_exhausted\"}}",
        @http_transport.JsonBody,
      )
  }
  let reload_route = head.target == "/v1/config/reload" &&
    head.method_name == "POST"
  if reload_route && head.content_length.unwrap_or(0) > 4096 {
    return self.reject(
      @http_transport.BodyTooLarge,
      "body_too_large",
      request_id,
      @management.RejectedParse,
    )
  }
  if head.target.contains("%") ||
    head.target.contains("?") ||
    head.target.contains("#") ||
    same_read_suffix_bytes != 0 ||
    (!reload_route && head.content_length is Some(length) && length != 0) ||
    (
      reload_route &&
      body.unwrap_or(b"").length() != head.content_length.unwrap_or(0)
    ) {
    return self.reject(
      @http_transport.BadRequest,
      "bad_request",
      request_id,
      @management.RejectedParse,
    )
  }
  for forbidden in ["transfer-encoding", "upgrade", "expect"] {
    if management_header(head, forbidden) is Some(_) {
      return self.reject(
        @http_transport.BadRequest,
        "bad_request",
        request_id,
        @management.RejectedParse,
      )
    }
  }
  let token = match management_header(head, "authorization") {
    Some(value) => management_bearer(value)
    None => None
  }
  let actor = match token {
    Some(value) => self.tokens.authenticate(value)
    None => None
  }
  let actor = match actor {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.Unauthorized,
        "unauthenticated",
        request_id,
        @management.RejectedAuth,
      )
  }
  if reload_route {
    if !actor.allows(@management.ConfigAdmin) {
      return self.reject(
        @http_transport.Forbidden,
        "forbidden",
        request_id,
        @management.RejectedRole,
      )
    }
    if self.reload_generation is None {
      return self.reject(
        @http_transport.ServiceUnavailable,
        "reload_disabled",
        request_id,
        @management.RejectedOther,
      )
    }
  }
  if !reload_route && !actor.allows(@management.Operator) {
    return self.reject(
      @http_transport.Forbidden,
      "forbidden",
      request_id,
      @management.RejectedRole,
    )
  }
  let mut if_match : String? = None
  let mut idempotency_key : String? = None
  for header in head.headers {
    if header.name == "if-match" {
      if if_match is Some(_) {
        return self.reject(
          @http_transport.BadRequest,
          "bad_request",
          request_id,
          @management.RejectedParse,
        )
      }
      if_match = Some(header.value)
    } else if header.name == "idempotency-key" {
      if idempotency_key is Some(_) {
        return self.reject(
          @http_transport.BadRequest,
          "bad_request",
          request_id,
          @management.RejectedParse,
        )
      }
      idempotency_key = Some(header.value)
    }
  }
  if if_match is None || idempotency_key is None {
    return self.reject(
      @http_transport.PreconditionRequired,
      "precondition_required",
      request_id,
      @management.RejectedParse,
    )
  }
  let spec = match
    @management.parse_command(
      head.method_name,
      head.target,
      if_match.unwrap(),
      idempotency_key.unwrap(),
      actor.token_id(),
    ) {
    Ok(value) => value
    Err(_) =>
      return self.reject(
        @http_transport.BadRequest,
        "bad_request",
        request_id,
        @management.RejectedParse,
      )
  }
  if reload_route {
    let content_length = head.content_length.unwrap_or(0)
    if content_length > 0 {
      let mut content_type_count = 0
      for header in head.headers {
        if header.name == "content-type" {
          content_type_count += 1
          if header.value != "application/json" {
            return self.reject(
              @http_transport.UnsupportedMediaType,
              "unsupported_media_type",
              request_id,
              @management.RejectedParse,
            )
          }
        }
      }
      if content_type_count != 1 {
        return self.reject(
          @http_transport.BadRequest,
          "bad_request",
          request_id,
          @management.RejectedParse,
        )
      }
    }
    let expected = match @management.parse_reload_body(body.unwrap_or(b"")) {
      Ok(value) => value
      Err(_) =>
        return self.reject(
          @http_transport.BadRequest,
          "bad_request",
          request_id,
          @management.RejectedParse,
        )
    }
    if expected is Some(value) && value.to_string() != spec.target {
      return self.reject(
        @http_transport.PreconditionFailed,
        "precondition_failed",
        request_id,
        @management.RejectedParse,
      )
    }
  }
  if !reload_route && !self.config.operations_enabled() {
    return self.reject(
      @http_transport.ServiceUnavailable,
      "operations_disabled",
      request_id,
      @management.RejectedOther,
    )
  }
  if now_monotonic_ms < 0L ||
    @budget.admit([(self.command_bucket, 1L)], now_monotonic_ms) is Err(_) {
    return self.reject(
      @http_transport.TooManyRequests,
      "rate_limited",
      request_id,
      @management.RejectedRate,
    )
  }
  let mailbox = match self.command_mailbox {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.ServiceUnavailable,
        "unavailable",
        request_id,
        @management.RejectedOther,
      )
  }
  let ticket = match mailbox.submit(spec, actor) {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.TooManyRequests,
        "capacity_exhausted",
        request_id,
        @management.RejectedCapacity,
      )
  }
  defer mailbox.release(ticket)
  let reply = @async.with_timeout_opt(self.config.request_timeout_ms(), () => {
    mailbox.wait(ticket)
  }) catch {
    _ => None
  }
  match reply {
    Some(Some(value)) =>
      self.encode(
        value.status,
        value.body,
        @http_transport.JsonBody,
        location?=value.location,
      )
    _ =>
      self.reject(
        @http_transport.ServiceUnavailable,
        "unavailable",
        request_id,
        @management.RejectedDeadline,
      )
  }
}

///|
pub async fn ManagementHttp::respond_operation(
  self : ManagementHttp,
  head : @http_transport.HttpRequestHead,
  same_read_suffix_bytes : Int,
  now_monotonic_ms : Int64,
) -> Bytes {
  let request_id = match self.request_id() {
    Some(value) => value
    None =>
      return self.encode(
        @http_transport.ServiceUnavailable,
        b"{\"error\":{\"code\":\"id_exhausted\"}}",
        @http_transport.JsonBody,
      )
  }
  if head.method_name != "GET" ||
    (head.target.contains("?") && !head.target.has_prefix("/v1/audit?")) ||
    head.target.contains("%") ||
    head.target.contains("#") ||
    same_read_suffix_bytes != 0 ||
    (head.content_length is Some(length) && length != 0) {
    return self.reject(
      @http_transport.BadRequest,
      "bad_request",
      request_id,
      @management.RejectedParse,
    )
  }
  let token = match management_header(head, "authorization") {
    Some(value) => management_bearer(value)
    None => None
  }
  let actor = match token {
    Some(value) => self.tokens.authenticate(value)
    None => None
  }
  let actor = match actor {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.Unauthorized,
        "unauthenticated",
        request_id,
        @management.RejectedAuth,
      )
  }
  if !actor.allows(@management.Operator) &&
    !actor.allows(@management.ConfigAdmin) {
    return self.reject(
      @http_transport.Forbidden,
      "forbidden",
      request_id,
      @management.RejectedRole,
    )
  }
  if now_monotonic_ms < 0L ||
    @budget.admit([(self.request_bucket, 1L)], now_monotonic_ms) is Err(_) {
    return self.reject(
      @http_transport.TooManyRequests,
      "rate_limited",
      request_id,
      @management.RejectedRate,
    )
  }
  if !self.config.operations_enabled() &&
    !(self.reload_generation is Some(_) && actor.allows(@management.ConfigAdmin)) {
    return self.reject(
      @http_transport.ServiceUnavailable,
      "operations_disabled",
      request_id,
      @management.RejectedOther,
    )
  }
  let target = head.target
  let spec : @management.QuerySpec = if target == "/v1/audit" ||
    target.has_prefix("/v1/audit?") {
    match
      @management.parse_read_query(
        target,
        actor.token_id(),
        self.config.default_page_size(),
        self.config.max_page_size(),
      ) {
      Ok(value) if value.kind == @management.Audit => value
      _ =>
        return self.reject(
          @http_transport.BadRequest,
          "bad_request",
          request_id,
          @management.RejectedParse,
        )
    }
  } else {
    let prefix = "/v1/operations/"
    if !target.has_prefix(prefix) || target.length() <= prefix.length() {
      return self.reject(
        @http_transport.BadRequest,
        "bad_request",
        request_id,
        @management.RejectedParse,
      )
    }
    {
      kind: @management.Operation,
      target: target[prefix.length():].to_owned(),
      actor_token_id: actor.token_id(),
      limit: 1,
      cursor: None,
      filters: "",
    }
  }
  let mailbox = match self.query_mailbox {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.ServiceUnavailable,
        "details_unavailable",
        request_id,
        @management.RejectedOther,
      )
  }
  let ticket = match mailbox.submit(spec) {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.TooManyRequests,
        "capacity_exhausted",
        request_id,
        @management.RejectedCapacity,
      )
  }
  defer mailbox.release(ticket)
  let reply = @async.with_timeout_opt(self.config.query_timeout_ms(), () => {
    mailbox.wait(ticket)
  }) catch {
    _ => None
  }
  match reply {
    Some(Some(value)) =>
      self.encode(value.status, value.body, @http_transport.JsonBody)
    _ =>
      self.reject(
        @http_transport.ServiceUnavailable,
        "unavailable",
        request_id,
        @management.RejectedDeadline,
      )
  }
}

///|
/// ConfigAdmin reads only the boot-scoped generation identity. Neither source
/// paths nor policy/material fingerprints enter this response.
pub fn ManagementHttp::respond_reload_config(
  self : ManagementHttp,
  head : @http_transport.HttpRequestHead,
  same_read_suffix_bytes : Int,
  now_monotonic_ms : Int64,
) -> Bytes {
  let request_id = match self.request_id() {
    Some(value) => value
    None =>
      return self.encode(
        @http_transport.ServiceUnavailable,
        b"{\"error\":{\"code\":\"id_exhausted\"}}",
        @http_transport.JsonBody,
      )
  }
  if head.method_name != "GET" ||
    head.target != "/v1/config" ||
    same_read_suffix_bytes != 0 ||
    (head.content_length is Some(length) && length != 0) {
    return self.reject(
      @http_transport.BadRequest,
      "bad_request",
      request_id,
      @management.RejectedParse,
    )
  }
  let actor = match management_header(head, "authorization") {
    Some(value) =>
      match management_bearer(value) {
        Some(token) => self.tokens.authenticate(token)
        None => None
      }
    None => None
  }
  let actor = match actor {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.Unauthorized,
        "unauthenticated",
        request_id,
        @management.RejectedAuth,
      )
  }
  if !actor.allows(@management.ConfigAdmin) {
    return self.reject(
      @http_transport.Forbidden,
      "forbidden",
      request_id,
      @management.RejectedRole,
    )
  }
  if now_monotonic_ms < 0L ||
    @budget.admit([(self.request_bucket, 1L)], now_monotonic_ms) is Err(_) {
    return self.reject(
      @http_transport.TooManyRequests,
      "rate_limited",
      request_id,
      @management.RejectedRate,
    )
  }
  let handle = match self.reload_generation {
    Some(value) => value
    None =>
      return self.reject(
        @http_transport.ServiceUnavailable,
        "reload_disabled",
        request_id,
        @management.RejectedOther,
      )
  }
  let active = handle.active()
  let body : Map[String, Json] = Map([
    ("api_version", "1".to_json()),
    ("boot_id", self.boot_id.to_json()),
    ("config_epoch", active.config_epoch().to_string().to_json()),
    ("policy_epoch", active.policy_epoch().to_string().to_json()),
  ])
  self.encode(
    @http_transport.Ok,
    @utf8.encode(body.to_json().stringify()),
    @http_transport.JsonBody,
    etag=@management.config_etag(self.boot_id, active.config_epoch()),
  )
}
