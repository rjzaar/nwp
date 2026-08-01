/* NWP Console WebAuthn helpers — passkey-only auth.
 * Talks to /webauthn/{register,login}/{options,verify}. No frameworks. */
'use strict';

function b64uToBuf(s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  const bin = atob(s);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

function bufToB64u(buf) {
  const bytes = new Uint8Array(buf);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function postJSON(url, payload) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify(payload),
  });
  if (!r.ok) {
    let detail = 'HTTP ' + r.status;
    try { detail = (await r.json()).detail || detail; } catch (e) { /* keep */ }
    throw new Error(detail);
  }
  return r.json();
}

async function nwpEnroll(token) {
  if (!window.PublicKeyCredential) throw new Error('this browser has no WebAuthn support');
  const opts = await postJSON('/webauthn/register/options', { token });
  opts.challenge = b64uToBuf(opts.challenge);
  opts.user.id = b64uToBuf(opts.user.id);
  (opts.excludeCredentials || []).forEach((c) => { c.id = b64uToBuf(c.id); });
  const cred = await navigator.credentials.create({ publicKey: opts });
  const payload = {
    id: cred.id,
    rawId: bufToB64u(cred.rawId),
    type: cred.type,
    response: {
      clientDataJSON: bufToB64u(cred.response.clientDataJSON),
      attestationObject: bufToB64u(cred.response.attestationObject),
      // How this authenticator can be reached ('usb','nfc' / 'internal' / 'hybrid').
      // Recorded so /users can say WHICH key each row is; older browsers lack
      // getTransports(), so an empty list must stay a valid enrolment.
      transports: (cred.response.getTransports ? cred.response.getTransports() : []),
    },
    clientExtensionResults: cred.getClientExtensionResults(),
  };
  if (cred.authenticatorAttachment) payload.authenticatorAttachment = cred.authenticatorAttachment;
  return postJSON('/webauthn/register/verify', { token, credential: payload });
}

async function nwpLogin(username) {
  if (!window.PublicKeyCredential) throw new Error('this browser has no WebAuthn support');
  const opts = await postJSON('/webauthn/login/options', { username: username || '' });
  opts.challenge = b64uToBuf(opts.challenge);
  (opts.allowCredentials || []).forEach((c) => { c.id = b64uToBuf(c.id); });
  if (opts.allowCredentials && opts.allowCredentials.length === 0) delete opts.allowCredentials;
  const cred = await navigator.credentials.get({ publicKey: opts });
  const payload = {
    id: cred.id,
    rawId: bufToB64u(cred.rawId),
    type: cred.type,
    response: {
      clientDataJSON: bufToB64u(cred.response.clientDataJSON),
      authenticatorData: bufToB64u(cred.response.authenticatorData),
      signature: bufToB64u(cred.response.signature),
      userHandle: cred.response.userHandle ? bufToB64u(cred.response.userHandle) : null,
    },
    clientExtensionResults: cred.getClientExtensionResults(),
  };
  if (cred.authenticatorAttachment) payload.authenticatorAttachment = cred.authenticatorAttachment;
  return postJSON('/webauthn/login/verify', { credential: payload });
}
