# Deribit RPC Tasks

## Development Status Update (May 2025)

### ✅ Recently Completed
- Other tasks have been moved to docs/archive/completed_deribit_task.md

### 🚀 Next Up

### 📊 Progress: 0/0 tasks completed (100%)

## Current Tasks

| ID        | Description                                                                                                                      | Status  | Priority | Assignee | Review Rating |
| --------- | -------------------------------------------------------------------------------------------------------------------------------- | ------- | -------- | -------- | ------------- |

## Task Details


Step-by-Step Plan to Extract Deribit Implementation into a Standalone Library

## Phase 1: Preparation and Analysis

1. **Set up a new Elixir library project with supervision**
   - Run `mix new deribit_ex --module DeribitEx --sup`
   - Configure project settings in `mix.exs` (dependencies, description, etc.)
   - Set up the same development tools (.formatter.exs, .credo.exs, etc.)

2. **Analyze dependencies**
   - Review all Deribit-related modules
   - Identify external dependencies used by the Deribit modules
   - Define which modules from market_maker are required vs. what needs to be reimplemented

3. **Plan module namespace structure**
   - Design the new library's module hierarchy (e.g., `DeribitEx.Client`, `DeribitEx.RPC`, etc.)
   - Create a mapping from old module names to new ones

## Phase 2: Initial Migration

4. **Set up core infrastructure**
   - Create directory structure for the new project
   - Configure mix.exs with required dependencies 
   - Port over any utility modules needed by the Deribit code
   - Required dependencies:
     - `:websockex_nova` - WebSocket client with reconnect capabilities
     - `:jason` - JSON parsing
     - `:telemetry` - Metrics and instrumentation
     - Any additional dependencies identified during analysis

5. **Migrate core modules**
   - Move and rename `deribit_client.ex` → `DeribitEx.Client`
   - Move and rename `deribit_rpc.ex` → `DeribitEx.RPC`
   - Update module references within these files

6. **Move supporting modules**
   - Port rate limit handler, token manager, and other supporting modules
   - Ensure proper namespace updates
   - Files to migrate:
     - `/lib/market_maker/ws/deribit_client.ex` → `/lib/deribit_ex/client.ex`
     - `/lib/market_maker/ws/deribit_rpc.ex` → `/lib/deribit_ex/rpc.ex`
     - `/lib/market_maker/ws/deribit_rate_limit_handler.ex` → `/lib/deribit_ex/rate_limit_handler.ex`
     - `/lib/market_maker/ws/deribit_adapter.ex` → `/lib/deribit_ex/adapter.ex`
     - `/lib/market_maker/ws/deribit_adapter_extensions.ex` → `/lib/deribit_ex/adapter/extensions.ex`
     - `/lib/market_maker/ws/deribit_adapter_integration.ex` → `/lib/deribit_ex/adapter/integration.ex`
     - `/lib/market_maker/ws/token_manager.ex` → `/lib/deribit_ex/token_manager.ex`
     - `/lib/market_maker/ws/session_context.ex` → `/lib/deribit_ex/session_context.ex`
     - `/lib/market_maker/ws/resubscription_handler.ex` → `/lib/deribit_ex/resubscription_handler.ex`
     - `/lib/market_maker/ws/time_sync_service.ex` → `/lib/deribit_ex/time_sync_service.ex`
     - `/lib/market_maker/ws/time_sync_supervisor.ex` → `/lib/deribit_ex/time_sync_supervisor.ex`

## Phase 3: Tests and Documentation

7. **Migrate test files**
   - Port over all Deribit-related tests, updating references
   - Set up test helpers and fixtures as needed
   - Ensure all tests pass in the new environment
   - Test files to migrate:
     - `/test/market_maker/ws/deribit_client_*.exs` → `/test/deribit_ex/client_*_test.exs`
     - `/test/market_maker/ws/deribit_rpc_*.exs` → `/test/deribit_ex/rpc_*_test.exs`
     - `/test/market_maker/ws/deribit_adapter_*.exs` → `/test/deribit_ex/adapter_*_test.exs`
     - `/test/market_maker/ws/deribit_rate_limit_handler_test.exs` → `/test/deribit_ex/rate_limit_handler_test.exs`
     - `/test/integration/deribit_*_test.exs` → `/test/integration/*_test.exs`

8. **Create documentation**
   - Write module and function documentation
   - Create README.md with usage examples
   - Add typespecs to all public functions

## Phase 4: Refactoring and Optimization

9. **Configure the supervision tree**
   - Properly set up `DeribitEx.Application` with all necessary supervisors
   - Ensure Registry is included for dynamic processes
   - Set up proper supervision strategy for WebSocket connections
   - Structure the supervision trees for:
     - Connection management
     - Token management
     - Time synchronization
     - Rate limiting
     - Subscription management

10. **Refactor for independence**
   - Remove any dependencies on market_maker-specific code
   - Generalize functionality that's currently market_maker-specific
   - Create proper interfaces for external interaction
   - Specific components to refactor:
     - Replace `:deribit_ex` configuration with `:deribit_ex` configuration
     - Ensure TimeSyncService and TimeSyncSupervisor are properly included in supervision tree
     - Update telemetry event names to use the new library namespace
     - Remove any market_maker-specific business logic that doesn't belong in the library

11. **Optimize for library use**
    - Create a simplified public API
    - Add configuration options
    - Ensure proper error handling throughout the library
    - Provide clear documentation on supervision structure

## Phase 5: Integration and Testing

12. **Set up integration tests**
    - Create integration test suite for the library
    - Test against Deribit testnet
    - Document integration test procedures
    - Test process supervision and recovery scenarios

13. **Update market_maker to use the new library**
    - Add the new library as a dependency to market_maker
    - Replace all direct Deribit code with calls to the new library
    - Create adapter modules if necessary
    - Update existing tests to work with the library

## Phase 6: Publication and Maintenance

14. **Prepare for publication**
    - Set up CI/CD pipeline
    - Add license and contribution guidelines
    - Complete documentation
    - Include supervision tree diagram and explanation

15. **Publish initial version**
    - Publish to Hex.pm
    - Create a GitHub repository
    - Tag initial release

16. **Create maintenance plan**
    - Define versioning strategy
    - Plan for keeping in sync with Deribit API changes
    - Set up issue templates and contribution guidelines
    - Document process lifecycle and supervision strategies

Each step should be completed with careful testing to ensure functionality is preserved throughout the extraction process. This modular approach allows you to validate each piece as you go rather than attempting a single large migration.

Would you like me to elaborate on any specific part of this plan?