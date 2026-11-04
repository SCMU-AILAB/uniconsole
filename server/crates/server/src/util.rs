//! 小工具。

use serde::{Deserialize, Deserializer};

/// 区分「字段缺省」与「显式 null」：
/// `#[serde(default, deserialize_with = "double_option")] x: Option<Option<T>>`
/// - 缺省 → `None`（不修改）
/// - `null` → `Some(None)`（清空）
/// - 值 → `Some(Some(v))`
pub fn double_option<'de, T, D>(d: D) -> Result<Option<Option<T>>, D::Error>
where
    T: Deserialize<'de>,
    D: Deserializer<'de>,
{
    Option::<T>::deserialize(d).map(Some)
}

/// 账号：2–32 位小写字母、数字、`_`、`.`、`-`
pub fn normalize_handle(raw: &str) -> Option<String> {
    let h = raw.trim().trim_start_matches('@').to_lowercase();
    let ok = (2..=32).contains(&h.chars().count())
        && h.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "_.-".contains(c));
    ok.then_some(h)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[derive(Deserialize)]
    struct P {
        #[serde(default, deserialize_with = "double_option")]
        x: Option<Option<i32>>,
    }

    #[test]
    fn double_option_distinguishes_null() {
        let a: P = serde_json::from_value(json!({})).unwrap();
        let b: P = serde_json::from_value(json!({"x": null})).unwrap();
        let c: P = serde_json::from_value(json!({"x": 3})).unwrap();
        assert_eq!((a.x, b.x, c.x), (None, Some(None), Some(Some(3))));
    }

    #[test]
    fn handles() {
        assert_eq!(normalize_handle("@LinYue").as_deref(), Some("linyue"));
        assert_eq!(normalize_handle("a"), None);
        assert_eq!(normalize_handle("林悦"), None);
        assert_eq!(normalize_handle("zhou.ming_2"), Some("zhou.ming_2".into()));
    }
}
