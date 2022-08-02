defmodule Lightning.ScrubberTest do
  use ExUnit.Case, async: true

  alias Lightning.Scrubber

  describe "scrub/2" do
    test "with no samples or an empty string" do
      scrubber = start_supervised!(Lightning.Scrubber)
      assert Scrubber.scrub(scrubber, "foo bar") == "foo bar"
      assert Scrubber.scrub(scrubber, nil) == nil
    end

    test "when using a name registration" do
      start_supervised!({Lightning.Scrubber, name: :bar})
      assert Scrubber.scrub(:bar, "foo bar") == "foo bar"
    end

    test "replaces secrets in string with ***" do
      secrets = ["23", "taylor@openfn.org", "funpass000"]
      scrubber = start_supervised!({Lightning.Scrubber, samples: secrets})

      scrubbed =
        scrubber
        |> Scrubber.scrub([
          "Successfully logged in as taylor@openfn.org using funpass000"
        ])

      assert scrubbed == ["Successfully logged in as *** using ***"]
    end

    test "replaces Base64 encoded secrets in string with ***" do
      secrets = ["23", "taylor@openfn.org", "funpass000"]
      scrubber = start_supervised!({Lightning.Scrubber, samples: secrets})

      auth = Base.encode64("taylor@openfn.org:funpass000")

      scrubbed =
        scrubber
        |> Scrubber.scrub(
          "request headers: { authentication: '#{auth}', content-type: 'whatever' }"
        )

      assert scrubbed ==
               "request headers: { authentication: '***', content-type: 'whatever' }"
    end

    test "doesn't be hack itself by exposing longer secrets via shorter ones" do
      secrets = ["a", "secretpassword"]
      scrubber = start_supervised!({Lightning.Scrubber, samples: secrets})

      scrubbed =
        scrubber
        |> Scrubber.scrub("The password is secretpassword")

      assert scrubbed == "The p***ssword is ***"
    end
  end

  describe "encode_samples/1" do
    test "creates base64 pairs of all samples and adds them to the initial samples" do
      secrets = ["a", "secretpassword"]

      assert Scrubber.encode_samples(secrets) == [
               "c2VjcmV0cGFzc3dvcmQ6c2VjcmV0cGFzc3dvcmQ=",
               "YTpzZWNyZXRwYXNzd29yZA==",
               "c2VjcmV0cGFzc3dvcmQ6YQ==",
               "secretpassword",
               "YTph",
               "a"
             ]
    end
  end
end
