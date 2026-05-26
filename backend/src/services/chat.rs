use chrono::{DateTime, Utc};
use diesel::prelude::*;
use diesel::PgConnection;

use crate::schema::group_membership;
use crate::services::unread::UnreadService;

pub fn indefinite_mute_until() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("9999-12-31T23:59:59Z")
        .expect("valid indefinite mute timestamp")
        .with_timezone(&Utc)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatReadState {
    pub last_read_message_id: Option<i64>,
    pub unread_count: i64,
}

pub fn get_chat_last_read_message_id(
    conn: &mut PgConnection,
    chat_id: i64,
    uid: i32,
) -> Result<Option<i64>, diesel::result::Error> {
    use crate::schema::group_membership::dsl as gm_dsl;

    group_membership::table
        .filter(gm_dsl::chat_id.eq(chat_id).and(gm_dsl::uid.eq(uid)))
        .select(gm_dsl::last_read_message_id)
        .first(conn)
}

pub fn mark_chat_as_read(
    conn: &mut PgConnection,
    chat_id: i64,
    uid: i32,
    message_id: i64,
) -> Result<bool, diesel::result::Error> {
    use crate::schema::group_membership::dsl as gm_dsl;

    let updated = diesel::update(
        group_membership::table.filter(
            gm_dsl::chat_id.eq(chat_id).and(gm_dsl::uid.eq(uid)).and(
                gm_dsl::last_read_message_id
                    .is_null()
                    .or(gm_dsl::last_read_message_id.lt(message_id)),
            ),
        ),
    )
    .set(gm_dsl::last_read_message_id.eq(Some(message_id)))
    .execute(conn)?;

    Ok(updated > 0)
}

pub fn mark_chat_as_read_state(
    conn: &mut PgConnection,
    unread_service: &UnreadService,
    chat_id: i64,
    uid: i32,
    message_id: i64,
) -> Result<ChatReadState, diesel::result::Error> {
    mark_chat_as_read(conn, chat_id, uid, message_id)?;

    let last_read_message_id = get_chat_last_read_message_id(conn, chat_id, uid)?;
    let unread_count = unread_service.count_chat_unread(conn, chat_id, last_read_message_id)?;

    Ok(ChatReadState {
        last_read_message_id,
        unread_count,
    })
}

#[cfg(test)]
mod tests {
    use crate::constants::MAX_UNREAD_COUNT;

    #[test]
    fn unread_count_cap_matches_display_overflow_boundary() {
        assert_eq!(MAX_UNREAD_COUNT, 1000);
    }
}
