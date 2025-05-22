# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-05-22

### Added
- Comprehensive coding and testing guidelines in CLAUDE.md
- Enhanced documentation with code quality standards and integration testing requirements
- Test request and heartbeat message handling for backward compatibility

### Changed
- Updated websockex_nova dependency to ~> 0.1.1 for latest features
- Simplified heartbeat handling to be stateless for improved performance
- Moved test_request handling from message level to frame level for better reliability
- Removed FrameHandler alias and behavior to simplify module structure

### Fixed
- Corrected config module references in TimeSyncService tests
- Fixed connection PID handling in ReconnectMonitor tests
- Updated adapter implementation to use ConnectionHandler instead of FrameHandler

## [0.1.0] - 2025-05-21

### Added
- Initial release of DeribitEx
- WebSocket-based client for Deribit API
- Authentication and token management
- Request/response handling via JSON-RPC
- Subscription and resubscription handling
- Time synchronization with server
- Rate limiting implementation
- Cancel-on-disconnect safety features
- Telemetry integration for monitoring
- Comprehensive test suite