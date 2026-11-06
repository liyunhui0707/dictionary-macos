# Security

Do not report API keys, extension tokens, private documents or personal machine
configuration in public Issues. For a suspected vulnerability, use GitHub's private
vulnerability reporting if enabled. If no private reporting channel is available,
open an Issue asking the maintainer to arrange one without disclosing exploit
steps or sensitive data. No guaranteed response time is currently offered.

The local integration server binds to loopback and authenticates extension requests.
Treat its token as a credential. Regenerate a compromised token through the app and
update your integrations. Revoke compromised cloud keys with the cloud provider.
