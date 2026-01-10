# Contributing to Converge Ledger

Thank you for your interest in contributing to Converge Ledger.

This document outlines the development workflow, testing requirements, and code quality standards.

⸻

## Development Setup

```bash
# Clone the repository
git clone <repository-url>
cd converge_context

# Install dependencies
just deps

# Run initial setup
just setup

# Run tests to verify setup
just test
```

⸻

## Testing Philosophy

Converge Ledger uses a comprehensive testing strategy combining:

1. **Unit Tests** — Verify specific functionality with fixed inputs
2. **Property-Based Tests** — Validate invariants across generated data
3. **Integration Tests** — Exercise end-to-end workflows
4. **Entry Type Coverage** — Test all supported entry types including evaluations

All tests must pass before contributions are accepted.

⸻

## Running Tests

### All Tests

```bash
just test
# or
mix test
```

### With Coverage

```bash
just test-cover
# or
mix test --cover
```

### Specific Test Files

```bash
# Run a specific test file
mix test test/converge_context/entry_test.exs

# Run tests matching a pattern
mix test --only property
```

⸻

## Test Structure

### Unit Tests

Unit tests verify specific behaviors with known inputs. They are located alongside property tests in each test file.

Example from `entry_test.exs`:

```elixir
test "generates unique 32-character hex ID" do
  entry1 = Entry.new("ctx", "key", "payload", 1)
  entry2 = Entry.new("ctx", "key", "payload", 2)

  assert String.length(entry1.id) == 32
  assert entry1.id != entry2.id
end
```

### Property-Based Tests

Property-based tests use `ExUnitProperties` and `StreamData` to generate random inputs and verify invariants hold across all cases.

**Key Property Test Areas:**

1. **Entry Creation** (`entry_test.exs`)
   - Entry validity across all generated inputs
   - ID uniqueness guarantees
   - Timestamp monotonicity
   - Record round-trip preservation

2. **Store Operations** (`store_test.exs`)
   - Append/get round-trip correctness
   - Sequence number monotonicity
   - Context isolation
   - Key filtering accuracy
   - Pagination with limits

3. **Snapshot/Load** (`snapshot_test.exs`)
   - Snapshot/load round-trip preservation
   - Metadata accuracy
   - Sequence ordering maintenance
   - Empty context handling

4. **Watch Registry** (`watch_registry_test.exs`)
   - Subscription management
   - Notification delivery guarantees
   - Key filter correctness
   - Process cleanup

**Property Test Generators:**

All property tests use generators to create test data:

```elixir
# Context IDs (unique per check)
defp context_id_gen do
  StreamData.map(
    StreamData.binary(length: 8),
    fn bytes -> Base.encode16(bytes, case: :lower) end
  )
end

# Entry keys (including evaluations)
defp key_gen do
  StreamData.member_of([
    "facts",
    "intents",
    "traces",
    "evaluations",  # Evaluation entries
    "hypotheses",
    "signals"
  ])
end

# Payloads (binary data)
defp payload_gen do
  StreamData.binary(min_length: 1, max_length: 512)
end

# Metadata maps
defp metadata_gen do
  StreamData.map_of(
    StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
    StreamData.string(:printable, max_length: 64),
    max_length: 5
  )
end
```

### Entry Types and Evaluations

The ledger supports multiple entry types, including **evaluations**:

- `facts` — Observable facts
- `intents` — Declared objectives
- `traces` — Execution traces
- `evaluations` — Evaluation results (confidence scores, feasibility assessments, etc.)
- `hypotheses` — Proposed explanations
- `signals` — External signals

All entry types are tested through property tests that generate random keys from the supported set. Evaluation entries are treated identically to other entry types — the ledger is agnostic to entry semantics.

**Example: Testing Evaluation Entries**

```elixir
property "evaluation entries are preserved correctly" do
  check all(
          context_id <- context_id_gen(),
          payload <- payload_gen(),
          metadata <- metadata_gen()
        ) do
    {:ok, entry} = Store.append(context_id, "evaluations", payload, metadata)
    {:ok, [retrieved], _} = Store.get(context_id, key: "evaluations")
    
    assert retrieved.key == "evaluations"
    assert retrieved.payload == payload
    assert retrieved.metadata == metadata
  end
end
```

### Integration Tests

Integration tests in `converge_context_test.exs` verify:

- Public API delegation
- End-to-end workflows (append → get → snapshot → load)
- Incremental sync patterns
- Key filtering across entry types
- Pagination behavior

⸻

## Code Quality

### Formatting

Code must be formatted with `mix format`:

```bash
just fmt
# or
mix format
```

Check formatting in CI:

```bash
just fmt-check
# or
mix format --check-formatted
```

### Linting

Run Credo with strict mode:

```bash
just lint
# or
mix credo --strict
```

### Type Checking

Run Dialyzer:

```bash
just dialyzer
# or
mix dialyzer
```

### Full CI Check

Run all quality checks:

```bash
just ci
```

This runs:
- Format check
- Linting
- All tests

⸻

## Test Coverage Requirements

- **Unit tests** must cover edge cases (empty inputs, large inputs, special characters)
- **Property tests** must verify invariants across generated data
- **Integration tests** must cover complete workflows
- All entry types (including evaluations) must be exercised

Aim for high coverage, but focus on meaningful tests over coverage metrics.

⸻

## Writing Property Tests

When adding new functionality, include property tests that verify invariants.

**Structure:**

```elixir
describe "property: <feature name>" do
  property "invariant description" do
    check all(
            input1 <- generator1(),
            input2 <- generator2()
          ) do
      # Setup
      result = YourModule.function(input1, input2)
      
      # Verify invariants
      assert invariant1_holds?(result)
      assert invariant2_holds?(result)
    end
  end
end
```

**Best Practices:**

1. Use unique context IDs per property check to avoid test interference
2. Clear Mnesia state in setup when needed
3. Test both positive and negative cases
4. Verify ordering, uniqueness, and isolation properties
5. Test with various input sizes (small, medium, large)

⸻

## Test File Organization

```
test/
├── test_helper.exs              # Test setup
├── converge_context_test.exs    # Integration tests
└── converge_context/
    ├── entry_test.exs           # Entry unit + property tests
    ├── store_test.exs           # Store unit + property tests
    ├── snapshot_test.exs        # Snapshot unit + property tests
    └── watch_registry_test.exs  # Watch unit + property tests
```

Each test file contains:
1. Generators (private helper functions)
2. Unit tests (edge cases, specific behaviors)
3. Property tests (invariant verification)

⸻

## Mnesia Test Setup

Tests that use Mnesia must:

1. Start Mnesia in setup
2. Initialize schema
3. Wait for tables
4. Clear state between tests when needed

Example:

```elixir
setup do
  :mnesia.start()
  Schema.init()
  :mnesia.wait_for_tables([Schema.entries_table(), Schema.sequences_table()], 5000)
  Schema.clear_all()
  :ok
end
```

⸻

## Architectural Constraints

Remember: **Nothing in this system may influence convergence semantics.**

When writing tests:

- ✅ Test append-only semantics
- ✅ Test data preservation
- ✅ Test ordering guarantees
- ✅ Test isolation properties
- ❌ Do not test semantic validation (that's Converge Core's job)
- ❌ Do not test decision-making logic
- ❌ Do not test coordination protocols

⸻

## Pull Request Process

1. **Fork and branch** from main
2. **Write tests first** (TDD encouraged)
3. **Implement changes** with tests passing
4. **Run full CI** (`just ci`)
5. **Ensure all tests pass**, including property tests
6. **Update documentation** if API changes
7. **Submit PR** with clear description

**PR Checklist:**

- [ ] All tests pass (`just test`)
- [ ] Code is formatted (`just fmt-check`)
- [ ] Linting passes (`just lint`)
- [ ] Property tests cover new invariants
- [ ] Unit tests cover edge cases
- [ ] Documentation updated if needed
- [ ] No architectural violations

⸻

## Getting Help

- Review existing test files for patterns
- Check `ARCHITECTURE.md` for design principles
- Ensure tests align with the "derivative, not authoritative" principle

⸻

## Test Maintenance

When modifying code:

1. **Update tests** to match new behavior
2. **Add property tests** for new invariants
3. **Verify existing property tests** still pass
4. **Check test coverage** hasn't regressed

Property tests are especially valuable — they catch regressions that unit tests might miss.

⸻

## Summary

- **Test everything** — unit, property, and integration
- **Cover all entry types** — including evaluations
- **Verify invariants** — ordering, uniqueness, isolation
- **Maintain quality** — format, lint, type-check
- **Respect architecture** — no semantic authority

Thank you for contributing to Converge Ledger.
