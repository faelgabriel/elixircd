defmodule ElixIRCd.Utils.ValidationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Utils.Validation

  describe "validate_email/1" do
    test "returns :ok for valid emails with different formats" do
      valid_emails = [
        "simple@example.com",
        "very.common@example.com",
        "disposable.style.email.with+symbol@example.com",
        "other.email-with-dash@example.com",
        "fully-qualified-domain@example.com",
        "user.name+tag+sorting@example.com",
        "x@example.com",
        "example-indeed@strange-example.com",
        "example@s.example",
        "name.surname@example.com",
        "name1.surname1@subdomain.example.com",
        "name-with-dash@example.com",
        "a.b.c.d.e@example.com",
        "user@example123.com",
        "user@123example.com",
        "user@sub.123example.co.uk"
      ]

      for email <- valid_emails do
        assert :ok == Validation.validate_email(email), "Expected #{email} to be valid"
      end
    end

    test "returns error for invalid emails" do
      invalid_emails = [
        " ",
        "not_an_email",
        "missing_at.com",
        "@missing_local_part.com",
        "missing_domain@",
        "two@@at_signs.com",
        "invalid@domain",
        "invalid<character>@example.com",
        "spaces contain@example.com",
        "unicode_λ@example.com",
        "missing_tld@example.",
        "underscore_in@host_name.com",
        "double..dot@example.com",
        ".leading_dot@example.com",
        "trailing_dot.@example.com",
        "user%example.com@example.org",
        "user!special@example.org",
        " starts_with_space@example.com",
        "ends_with_space@example.com ",
        "too_long_local_part_" <> String.duplicate("a", 65) <> "@example.com",
        String.duplicate("a", 246) <> "@example.com"
      ]

      for email <- invalid_emails do
        assert {:error, :invalid_email} == Validation.validate_email(email), "Expected #{email} to be invalid"
      end
    end

    test "returns error for non-string input" do
      assert {:error, :invalid_email} == Validation.validate_email(nil)
    end
  end
end
