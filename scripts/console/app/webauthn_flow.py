"""WebAuthn ceremonies — thin wrapper over the `webauthn` (py_webauthn) lib.

Kept out of main.py so the unit-testable modules never import third-party
crypto. Challenges ride in a short-lived itsdangerous-signed cookie set by the
options endpoints and checked by the verify endpoints.

Passkey-only: registration prefers resident keys (discoverable credentials) so
both Solo hardware keys and phone platform passkeys work, and login can be
usernameless (empty allowCredentials => the authenticator offers its passkeys).
"""
from __future__ import annotations

from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)


def registration_options(rp_id: str, rp_name: str, username: str, existing_cred_ids_b64: list[str]) -> tuple[str, str]:
    """Returns (options_json_for_browser, challenge_b64url_to_stash)."""
    opts = generate_registration_options(
        rp_id=rp_id,
        rp_name=rp_name,
        user_id=username.encode(),
        user_name=username,
        user_display_name=username,
        exclude_credentials=[
            PublicKeyCredentialDescriptor(id=base64url_to_bytes(c)) for c in existing_cred_ids_b64
        ],
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.PREFERRED,
            user_verification=UserVerificationRequirement.PREFERRED,
        ),
    )
    return options_to_json(opts), bytes_to_base64url(opts.challenge)


def verify_registration(credential_json: str, challenge_b64: str, origin: str, rp_id: str) -> dict:
    v = verify_registration_response(
        credential=credential_json,
        expected_challenge=base64url_to_bytes(challenge_b64),
        expected_origin=origin,
        expected_rp_id=rp_id,
        require_user_verification=False,  # UV preferred, not required (Solo w/o PIN ok)
    )
    return {
        "cred_id_b64": bytes_to_base64url(v.credential_id),
        "public_key_b64": bytes_to_base64url(v.credential_public_key),
        "sign_count": v.sign_count,
    }


def authentication_options(rp_id: str, allowed_cred_ids_b64: list[str]) -> tuple[str, str]:
    """Empty allowed list => usernameless discoverable-credential flow."""
    opts = generate_authentication_options(
        rp_id=rp_id,
        allow_credentials=[
            PublicKeyCredentialDescriptor(id=base64url_to_bytes(c)) for c in allowed_cred_ids_b64
        ],
        user_verification=UserVerificationRequirement.PREFERRED,
    )
    return options_to_json(opts), bytes_to_base64url(opts.challenge)


def verify_authentication(
    credential_json: str, challenge_b64: str, origin: str, rp_id: str, public_key_b64: str, sign_count: int
) -> int:
    """Returns the new sign count (raises on any verification failure)."""
    v = verify_authentication_response(
        credential=credential_json,
        expected_challenge=base64url_to_bytes(challenge_b64),
        expected_origin=origin,
        expected_rp_id=rp_id,
        credential_public_key=base64url_to_bytes(public_key_b64),
        credential_current_sign_count=int(sign_count),
        require_user_verification=False,
    )
    return v.new_sign_count
