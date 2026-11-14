"""Offline configuration checks. No credentials, production API or database reads."""
from pathlib import Path
import re,hashlib,base64
ROOT=Path(__file__).resolve().parents[1]
text=(ROOT/'ThreeOneOSFive/helpers/AppSecurityConfiguration.swift').read_text(encoding='utf-8')
assert 'https://aimlockhzz.site' in text and 'astra-rsa-2026-01' in text
key=re.search(r'signingPublicKeyPKCS1Base64 = "([^"]+)"',text)[1]
assert hashlib.sha256(base64.b64decode(key)).hexdigest()=='d54126c8056e968935e0269624a6c53dc1ed345e5a0c62bfeb9dfaea3040bfe4'
assert 'SjzSZU44vxnR21HP6KwHfgfMQGx76tNxVt9eliXroMk=' in text
for path in (ROOT/'ThreeOneOSFive').rglob('*.swift'):
    data=path.read_text(encoding='utf-8')
    assert all(term not in data for term in ['QAConfiguration','trycloudflare.com','astra-qa-20261103','qa_patch_applied_']),str(path)
policy=(ROOT/'ThreeOneOSFive/helpers/SecureAPIClient.swift').read_text(encoding='utf-8')
assert '"/api/v2/security/integrity"' in policy
print('Production origin, signer, pin, persistent namespaces and integrity endpoint validated offline.')

assert '"/api/v2/security/integrity-v2"' in policy
