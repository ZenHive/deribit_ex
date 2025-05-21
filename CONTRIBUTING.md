# Contributing to DeribitEx

First off, thank you for considering contributing to DeribitEx! It's people like you that make the open source community such a great place to learn, inspire, and create.

## Code of Conduct

This project and everyone participating in it is governed by the [DeribitEx Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the issue list to see if the problem has already been reported. If it has and the issue is still open, add a comment to the existing issue instead of opening a new one.

When creating a bug report, include as many details as possible:

- Use a clear and descriptive title
- Describe the exact steps to reproduce the problem
- Describe the behavior you observed and the behavior you expected
- Include details about your environment (OS, Elixir version, etc.)
- Include any relevant logs or stack traces

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, include:

- A clear and descriptive title
- A detailed description of the proposed functionality
- Any potential implementation details you have in mind
- Why this enhancement would be useful to most users

### Pull Requests

- Fill in the required template
- Follow the Elixir style guide
- Include tests for new functionality
- Update documentation for any changed functionality
- Ensure all tests pass

## Development Workflow

1. Set up your development environment
   ```bash
   git clone https://github.com/username/deribit_ex.git
   cd deribit_ex
   mix deps.get
   ```

2. Create a new branch
   ```bash
   git checkout -b my-feature-branch
   ```

3. Make your changes
   - Write tests for new functionality
   - Update documentation as needed

4. Run the tests and quality checks
   ```bash
   mix test
   mix credo
   mix dialyzer
   mix doctor
   ```

5. Submit a pull request
   - Include a clear description of the changes
   - Reference any relevant issues
   - Update CHANGELOG.md with your changes under the "Unreleased" section

## Style Guide

- Follow the [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- Run `mix format` before committing to ensure consistency
- Use [Credo](https://github.com/rrrene/credo) to check for code style issues
- Add proper @moduledoc and @doc attributes to all modules and public functions
- Add @spec attributes to all public functions

## Documentation

- Update the documentation when changing functionality
- Use examples in documentation when possible
- Keep the README.md up to date

## Testing

All new features should be covered by tests:
- Unit tests for focused functionality
- Integration tests for API interactions

## Questions?

Feel free to contact the project maintainers if you have any questions or need help with the contribution process.