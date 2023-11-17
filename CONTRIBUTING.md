# Contributing to ElixIRCd

Thank you for considering contributing to ElixIRCd! This document outlines the guidelines and best practices to follow when contributing to this project.

### Bug Reports and Feature Requests

If you encounter a bug or have a feature request, please open an issue on the GitHub repository. Please include as much detail as possible in your report or request, such as steps to reproduce the bug or a clear description of the new feature.

### Pull Requests

Pull requests are always welcome! Before submitting a pull request, please ensure that:

- All existing tests pass
- New code is accompanied by tests that cover all cases
- The code is formatted according to the Elixir style guide
- The pull request contains a clear description of the changes made and why they are needed
- Each pull request should be kept small and focused on a single change or feature.
- Functions should be well-documented and follow the [Elixir documentation conventions](https://hexdocs.pm/elixir/writing-documentation.html).

### Code Conventions

Please follow the Elixir style guide for all code contributions. You can find the style guide at https://github.com/christopheradams/elixir_style_guide.

## Test Coverage

We aim to maintain a high level of test coverage for this project to ensure that it remains stable and bug-free. When submitting changes, please ensure that all tests pass and that any new code is covered by tests.

Our current test coverage target is 90%, as measured by [Coveralls](https://coveralls.io/). To check the current test coverage status, visit our [Coveralls page](https://coveralls.io/github/faelgabriel/elixircd).

To run tests locally and check your code's test coverage, run the following command:

```bash
mix coveralls
```

This will generate a coverage report and open it in your default web browser.
Note that if you're not using a graphical interface, the coverage report will be generated but won't open in a browser.
