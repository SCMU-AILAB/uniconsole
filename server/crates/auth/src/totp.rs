//! TOTP 二次验证（RFC 6238：HMAC-SHA1、30 秒步长、6 位数字），兼容常见验证器 App。

use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, KeyInit, Mac};
use sha1::Sha1;
use uuid::Uuid;

const STEP_SECS: i64 = 30;
const DIGITS: u32 = 6;

/// 生成 160 位随机密钥（base32，无填充）
pub fn generate_secret() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(Uuid::new_v4().as_bytes());
    // uuid v4 有 6 位固定版本位，取 20 字节时混合两段以保留足够熵
    let key: Vec<u8> = (0..20).map(|i| bytes[i] ^ bytes[31 - i]).collect();
    BASE32_NOPAD.encode(&key)
}

/// 给验证器 App 扫码用的 `otpauth://` 链接
pub fn otpauth_url(secret: &str, account: &str, issuer: &str) -> String {
    let enc = |s: &str| {
        s.bytes()
            .map(|b| match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                    (b as char).to_string()
                }
                _ => format!("%{b:02X}"),
            })
            .collect::<String>()
    };
    format!(
        "otpauth://totp/{}:{}?secret={secret}&issuer={}&algorithm=SHA1&digits={DIGITS}&period={STEP_SECS}",
        enc(issuer),
        enc(account),
        enc(issuer)
    )
}

fn code_for_counter(key: &[u8], counter: u64) -> u32 {
    let mut mac = Hmac::<Sha1>::new_from_slice(key).expect("HMAC 接受任意长度密钥");
    mac.update(&counter.to_be_bytes());
    let digest = mac.finalize().into_bytes();
    let offset = (digest[digest.len() - 1] & 0x0f) as usize;
    let bin = u32::from_be_bytes([
        digest[offset] & 0x7f,
        digest[offset + 1],
        digest[offset + 2],
        digest[offset + 3],
    ]);
    bin % 10u32.pow(DIGITS)
}

/// 某一时刻的验证码（测试与调试用）
pub fn code_at(secret: &str, unix_secs: i64) -> Option<String> {
    let key = BASE32_NOPAD.decode(secret.as_bytes()).ok()?;
    let counter = (unix_secs / STEP_SECS) as u64;
    Some(format!(
        "{:0width$}",
        code_for_counter(&key, counter),
        width = DIGITS as usize
    ))
}

/// 校验验证码，允许前后各一个步长的时钟偏差
pub fn verify(secret: &str, code: &str, unix_secs: i64) -> bool {
    let code = code.trim().replace(' ', "");
    if code.len() != DIGITS as usize || !code.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    let Ok(key) = BASE32_NOPAD.decode(secret.as_bytes()) else {
        return false;
    };
    let counter = unix_secs / STEP_SECS;
    (-1..=1).any(|d| {
        let c = (counter + d) as u64;
        format!(
            "{:0width$}",
            code_for_counter(&key, c),
            width = DIGITS as usize
        ) == code
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RFC 6238 附录 B 的 SHA1 测试向量（密钥 "12345678901234567890"）
    #[test]
    fn rfc6238_vectors() {
        let secret = BASE32_NOPAD.encode(b"12345678901234567890");
        // RFC 给出的是 8 位，取后 6 位
        for (t, expect8) in [
            (59, "94287082"),
            (1111111109, "07081804"),
            (1234567890, "89005924"),
            (2000000000, "69279037"),
        ] {
            assert_eq!(code_at(&secret, t).unwrap(), &expect8[2..], "t={t}");
        }
    }

    #[test]
    fn verify_with_drift() {
        let s = generate_secret();
        let now = 1_800_000_000;
        let code = code_at(&s, now).unwrap();
        assert!(verify(&s, &code, now));
        assert!(verify(&s, &code, now + 30));
        assert!(!verify(&s, &code, now + 90));
        assert!(!verify(&s, "12345", now));
        assert!(!verify(&s, "abcdef", now));
    }

    #[test]
    fn otpauth() {
        let u = otpauth_url("ABC", "kanade", "UniConsole");
        assert!(u.starts_with("otpauth://totp/UniConsole:kanade?secret=ABC"));
    }
}
