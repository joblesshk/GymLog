export type RelayScope = "asr" | "cleanup";

export interface RelayClaims {
  sub: string;
  exp: number;
  scopes: RelayScope[];
  jti?: string;
}

const encoder = new TextEncoder();

function encodeBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function decodeBase64URL(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/")
    + "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob(normalized);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function hmac(secret: string, value: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(value)));
}

export async function signRelayToken(claims: RelayClaims, secret: string): Promise<string> {
  const payload = encodeBase64URL(encoder.encode(JSON.stringify(claims)));
  const signature = encodeBase64URL(await hmac(secret, `v1.${payload}`));
  return `v1.${payload}.${signature}`;
}

export async function verifyRelayToken(
  authorization: string | null,
  secret: string | undefined,
  requiredScope: RelayScope,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<RelayClaims | null> {
  if (!secret || !authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice("Bearer ".length).trim();
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== "v1") return null;
  const [version, payload, providedSignature] = parts;
  const expectedSignature = await hmac(secret, `${version}.${payload}`);
  let actualSignature: Uint8Array;
  try {
    actualSignature = decodeBase64URL(providedSignature);
  } catch {
    return null;
  }
  if (actualSignature.length !== expectedSignature.length
      || !timingSafeEqual(actualSignature, expectedSignature)) return null;

  let claims: RelayClaims;
  try {
    claims = JSON.parse(new TextDecoder().decode(decodeBase64URL(payload))) as RelayClaims;
  } catch {
    return null;
  }
  if (!claims.sub || !Number.isFinite(claims.exp) || claims.exp <= nowSeconds) return null;
  if (!Array.isArray(claims.scopes) || !claims.scopes.includes(requiredScope)) return null;
  return claims;
}

function timingSafeEqual(lhs: Uint8Array, rhs: Uint8Array): boolean {
  if (lhs.length !== rhs.length) return false;
  let diff = 0;
  for (let index = 0; index < lhs.length; index += 1) diff |= lhs[index] ^ rhs[index];
  return diff === 0;
}
