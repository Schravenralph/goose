# Metrics Dashboard Security Documentation

This document describes the security features implemented in the production-ready metrics dashboard server.

## Security Features

### 1. Authentication

The server supports Basic HTTP authentication to restrict access to authorized users.

**Configuration:**
- Set `--auth-username` and `--auth-password` command-line arguments
- Passwords are hashed using SHA-256 before storage/comparison
- Authentication is enforced for all endpoints

**Usage:**
```bash
python3 serve-metrics-dashboard.py \
  --auth-username admin \
  --auth-password "secure-password-here"
```

**Security Considerations:**
- Basic auth sends credentials in base64-encoded format (not encrypted)
- **Always use HTTPS in production** to protect credentials in transit
- Consider using stronger authentication (OAuth, API keys) for high-security environments
- Rotate passwords regularly

### 2. Input Validation and Sanitization

All user inputs are validated and sanitized to prevent injection attacks and path traversal.

**Validated Inputs:**
- **Script names**: Only alphanumeric characters, dashes, and underscores allowed
- **Date strings**: Must be valid ISO 8601 format
- **File paths**: Validated to prevent directory traversal attacks
- **File sizes**: Limited to 10MB maximum

**Sanitization:**
- Null bytes and control characters are removed
- String lengths are limited to prevent buffer overflow attacks
- File extensions are validated against whitelist

### 3. Rate Limiting

Rate limiting prevents abuse and DoS attacks by limiting the number of requests per client IP.

**Configuration:**
- Default: 100 requests per 60 seconds per IP
- Configurable via `--rate-limit` and `--rate-limit-window`
- Uses sliding window algorithm

**Usage:**
```bash
python3 serve-metrics-dashboard.py \
  --rate-limit 50 \
  --rate-limit-window 30
```

**Behavior:**
- Requests exceeding the limit receive HTTP 429 (Too Many Requests)
- Rate limits are tracked per client IP address
- X-Forwarded-For header is respected for reverse proxy setups

### 4. Audit Logging

All security-relevant events are logged for monitoring and forensics.

**Logged Events:**
- Authentication attempts (success and failure)
- API access
- File access
- Rate limit violations
- Path traversal attempts
- Invalid file access attempts
- Errors and exceptions

**Log Format:**
```json
{
  "timestamp": "2025-01-02T12:34:56.789Z",
  "event_type": "dashboard_accessed",
  "client_ip": "192.168.1.100",
  "path": "/metrics-dashboard.html",
  "status_code": 200,
  "details": {}
}
```

**Configuration:**
- Default: Logs to stderr
- Optional: Log to file via `--audit-log` argument

**Usage:**
```bash
python3 serve-metrics-dashboard.py \
  --audit-log /var/log/goose-dashboard-audit.log
```

### 5. Secure File Handling

File operations are secured to prevent unauthorized access and resource exhaustion.

**Security Measures:**
- Path traversal protection (files must be within script directory)
- File size limits (10MB maximum)
- File extension whitelist (only `.json` files allowed)
- File existence and type validation

**File Size Limits:**
- Maximum file size: 10MB (configurable via `MAX_FILE_SIZE` constant)
- Files exceeding limit are rejected with HTTP 413

### 6. Security Headers

HTTP security headers are sent with all responses to prevent common web vulnerabilities.

**Headers Sent:**
- `X-Content-Type-Options: nosniff` - Prevents MIME type sniffing
- `X-Frame-Options: DENY` - Prevents clickjacking
- `X-XSS-Protection: 1; mode=block` - Enables XSS protection

**Note:** CORS headers are NOT sent by default (production security). Remove or configure if CORS is needed.

### 7. HTTPS Support

While the server itself doesn't handle TLS, HTTPS should be configured via reverse proxy.

**Recommended Setup:**
- Use nginx or Apache as reverse proxy
- Configure SSL/TLS certificates (Let's Encrypt recommended)
- Redirect HTTP to HTTPS
- Use strong cipher suites

## Security Best Practices

### Production Deployment Checklist

- [ ] Enable authentication (`--auth-username` and `--auth-password`)
- [ ] Configure HTTPS via reverse proxy
- [ ] Set up audit logging to persistent storage
- [ ] Configure appropriate rate limits
- [ ] Restrict network access (firewall rules)
- [ ] Use strong, unique passwords
- [ ] Regularly rotate passwords
- [ ] Monitor audit logs for suspicious activity
- [ ] Keep Python and dependencies updated
- [ ] Run server with minimal privileges (non-root user)
- [ ] Configure file system permissions appropriately
- [ ] Set up log rotation for audit logs

### Network Security

- **Firewall**: Only allow access from trusted networks/IPs
- **Reverse Proxy**: Use nginx/Apache with SSL termination
- **VPN**: Consider requiring VPN access for sensitive deployments
- **IP Whitelisting**: Configure firewall rules to restrict access

### Access Control

- **User Management**: Use strong, unique passwords for each user
- **Password Policy**: Enforce password complexity requirements
- **Session Management**: Consider implementing session timeouts (if upgrading to session-based auth)
- **Multi-Factor Authentication**: Consider MFA for high-security environments

### Monitoring and Alerting

- **Audit Logs**: Regularly review audit logs for suspicious activity
- **Rate Limit Alerts**: Monitor for repeated rate limit violations
- **Failed Authentication Alerts**: Alert on multiple failed login attempts
- **Error Monitoring**: Monitor for unusual error patterns

## Threat Model

### Addressed Threats

1. **Unauthorized Access**: Mitigated by authentication
2. **Path Traversal**: Mitigated by path validation
3. **DoS Attacks**: Mitigated by rate limiting
4. **Injection Attacks**: Mitigated by input validation
5. **Information Disclosure**: Mitigated by access control
6. **Clickjacking**: Mitigated by X-Frame-Options header
7. **XSS Attacks**: Mitigated by X-XSS-Protection header

### Known Limitations

1. **Basic Auth**: Credentials are base64-encoded, not encrypted (use HTTPS)
2. **Single User**: Only one user account supported (consider multi-user system)
3. **No Session Management**: Each request requires authentication
4. **No Password Expiration**: Passwords don't expire automatically
5. **No Account Lockout**: Failed attempts don't lock accounts

### Future Enhancements

- OAuth 2.0 integration
- Session-based authentication
- Multi-user support with roles
- Password expiration policies
- Account lockout after failed attempts
- API key authentication for programmatic access
- IP-based access control lists
- Request signing for API calls

## Troubleshooting

### Authentication Issues

**Problem**: Getting 401 Unauthorized errors
- **Solution**: Verify username and password are correct
- **Solution**: Check that credentials are properly URL-encoded if using browser
- **Solution**: Ensure HTTPS is used in production (some browsers block basic auth over HTTP)

### Rate Limiting Issues

**Problem**: Getting 429 Too Many Requests
- **Solution**: Reduce request frequency
- **Solution**: Increase rate limit: `--rate-limit 200`
- **Solution**: Increase window: `--rate-limit-window 120`

### File Access Issues

**Problem**: Getting 403 Forbidden for valid files
- **Solution**: Check file extension is in whitelist (`.json`)
- **Solution**: Verify file is within script directory
- **Solution**: Check file size is under 10MB limit

## References

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [OWASP Input Validation Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html)
- [RFC 7617: Basic Authentication](https://tools.ietf.org/html/rfc7617)
