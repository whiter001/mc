// retry_test.v — unit tests for the agent loop's retry policy helpers.
//
// Pure-function tests only: the retry loop itself drives channels and
// goroutines (provider.chat), which the V test runner can't reap — that
// path is verified manually.
module main

fn test_retry_backoff_ms_exponential() {
	assert retry_backoff_ms(1) == 1000
	assert retry_backoff_ms(2) == 2000
	assert retry_backoff_ms(3) == 4000
	assert retry_backoff_ms(4) == 8000
}

fn test_retry_backoff_ms_capped_at_30s() {
	assert retry_backoff_ms(5) == 16000
	assert retry_backoff_ms(6) == 30000
	assert retry_backoff_ms(7) == 30000
	assert retry_backoff_ms(100) == 30000
}

fn test_is_retryable_status() {
	// 429 (rate limit) and 5xx are transient.
	assert is_retryable_status(429)
	assert is_retryable_status(500)
	assert is_retryable_status(502)
	assert is_retryable_status(503)
	// Other 4xx are client errors a retry won't fix.
	assert !is_retryable_status(400)
	assert !is_retryable_status(401)
	assert !is_retryable_status(403)
	assert !is_retryable_status(404)
	assert !is_retryable_status(200)
}

fn test_provider_error_retryable_flag() {
	retryable_err := ProviderError{
		kind:      'http_429'
		message:   'http_429: rate limited'
		retryable: true
	}
	assert retryable_err.retryable
	assert retryable_err.msg() == 'http_429: rate limited'

	fatal_err := ProviderError{
		kind:      'http_400'
		message:   'http_400: bad request'
		retryable: false
	}
	assert !fatal_err.retryable
}
