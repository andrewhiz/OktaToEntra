# Security Policy

## Reporting a Vulnerability

If you find a security issue in OktaToEntra — for example, a way that credentials could be exposed, or a script injection risk — please **do not open a public GitHub Issue**.

Instead, report it privately via **GitHub's private vulnerability reporting**:

1. Go to the [Security tab](../../security) of this repository
2. Click **Report a vulnerability**
3. Describe the issue, steps to reproduce, and potential impact

You can expect an acknowledgement within a few business days. If the issue is confirmed, a fix will be released and you will be credited (unless you prefer to remain anonymous).

## Scope

This tool runs locally on your own machine under your own credentials. It does not have a backend, does not phone home, and does not store secrets outside of your local SecretStore vault. The main areas of concern would be:

- Credential handling (SecureString usage, vault storage)
- SQL injection via user-supplied input to the local SQLite database
- Script injection via data returned from the Okta or Graph APIs