-- ============================================================
-- Re:che トーク（生徒コミュニケーションツール・デモ版）テーブル定義
-- Supabase ダッシュボード → SQL Editor に丸ごと貼って RUN するだけ
-- （Re:alize / promo-playbook と同じプロジェクトに相乗り。既存テーブルには一切触れません）
-- ============================================================
-- ★これは「デモ版」です。誰でも読み書きできる設定のため、
--   本名・電話番号などの個人情報は入れない前提で使ってください。
--   本番版は専用プロジェクト＋認証＋厳格な権限設定で作り直します。
-- ============================================================

-- 1) 利用者（生徒・運営）
CREATE TABLE IF NOT EXISTS rtalk_users (
  id          TEXT PRIMARY KEY,            -- 端末で生成するID
  name        TEXT NOT NULL DEFAULT '',
  role        TEXT NOT NULL DEFAULT 'student',  -- 'student' | 'staff'
  icon        TEXT NOT NULL DEFAULT '🙂',  -- アイコン絵文字
  color       TEXT NOT NULL DEFAULT '#A8D8EA',
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- 2) ルーム（生徒1人につき専用グループ1つ）
CREATE TABLE IF NOT EXISTS rtalk_rooms (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL DEFAULT '',   -- 生徒名（運営側の表示名）
  type              TEXT NOT NULL DEFAULT 'student',
  student_id        TEXT,                        -- この部屋の持ち主（生徒）
  student_icon      TEXT DEFAULT '🙂',
  student_color     TEXT DEFAULT '#A8D8EA',
  last_msg_at       TIMESTAMPTZ DEFAULT NOW(),
  last_msg_preview  TEXT DEFAULT '',
  last_sender_role  TEXT DEFAULT '',
  needs_reply       BOOLEAN DEFAULT FALSE,       -- 未対応フラグ（生徒発言でON・運営返信でOFF）
  handled_by_name   TEXT DEFAULT '',             -- 最後に対応した運営
  handled_by_icon   TEXT DEFAULT '',
  handled_at        TIMESTAMPTZ,
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

-- 3) メッセージ
CREATE TABLE IF NOT EXISTS rtalk_messages (
  id            TEXT PRIMARY KEY,
  room_id       TEXT NOT NULL,
  sender_id     TEXT NOT NULL,
  sender_name   TEXT DEFAULT '',
  sender_role   TEXT DEFAULT '',
  sender_icon   TEXT DEFAULT '',
  sender_color  TEXT DEFAULT '',
  kind          TEXT NOT NULL DEFAULT 'text',  -- 'text'|'stamp'|'image'|'video'|'broadcast'
  body          TEXT DEFAULT '',               -- 本文 / スタンプ / メディアURL
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_rtalk_messages_room_time ON rtalk_messages (room_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rtalk_rooms_last ON rtalk_rooms (last_msg_at DESC);

-- 4) 既読（ルーム×人につき1行。この時刻までのメッセージは既読）
CREATE TABLE IF NOT EXISTS rtalk_reads (
  room_id      TEXT NOT NULL,
  user_id      TEXT NOT NULL,
  user_role    TEXT DEFAULT '',
  last_read_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (room_id, user_id)
);

-- 5) 一斉配信の履歴
CREATE TABLE IF NOT EXISTS rtalk_broadcasts (
  id           TEXT PRIMARY KEY,
  sender_name  TEXT DEFAULT '',
  sender_icon  TEXT DEFAULT '',
  body         TEXT DEFAULT '',
  sent_count   INTEGER DEFAULT 0,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- 6) 不具合報告（標準装備）
CREATE TABLE IF NOT EXISTS rtalk_bug_reports (
  id            TEXT PRIMARY KEY,
  reporter_name TEXT DEFAULT '',
  reporter_role TEXT DEFAULT '',
  body          TEXT DEFAULT '',
  page_info     TEXT DEFAULT '',
  resolved      BOOLEAN DEFAULT FALSE,
  resolved_by   TEXT DEFAULT '',
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- 7) グループのメンバー（グループトーク用）
CREATE TABLE IF NOT EXISTS rtalk_room_members (
  room_id     TEXT NOT NULL,
  user_id     TEXT NOT NULL,
  user_name   TEXT DEFAULT '',
  user_role   TEXT DEFAULT '',
  user_icon   TEXT DEFAULT '',
  user_color  TEXT DEFAULT '',
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (room_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_rtalk_members_user ON rtalk_room_members (user_id);

-- 8) ノート（ルームごとの掲示板）
CREATE TABLE IF NOT EXISTS rtalk_notes (
  id            TEXT PRIMARY KEY,
  room_id       TEXT NOT NULL,
  author_id     TEXT DEFAULT '',
  author_name   TEXT DEFAULT '',
  author_icon   TEXT DEFAULT '',
  author_color  TEXT DEFAULT '',
  title         TEXT DEFAULT '',
  body          TEXT DEFAULT '',
  image_url     TEXT DEFAULT '',
  pinned        BOOLEAN DEFAULT FALSE,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_rtalk_notes_room ON rtalk_notes (room_id, created_at DESC);

-- 9) アルバム
CREATE TABLE IF NOT EXISTS rtalk_albums (
  id            TEXT PRIMARY KEY,
  room_id       TEXT NOT NULL,
  title         TEXT DEFAULT '',
  cover_url     TEXT DEFAULT '',
  created_by    TEXT DEFAULT '',
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_rtalk_albums_room ON rtalk_albums (room_id);

CREATE TABLE IF NOT EXISTS rtalk_album_photos (
  id            TEXT PRIMARY KEY,
  album_id      TEXT NOT NULL,
  url           TEXT NOT NULL,
  uploader_id   TEXT DEFAULT '',
  uploader_name TEXT DEFAULT '',
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_rtalk_photos_album ON rtalk_album_photos (album_id, created_at DESC);

-- 画像・動画の保存先バケット
-- ※環境によっては storage への変更が権限エラーになるため、
--   エラーが出ても他のテーブル作成が巻き戻らないように保護しています。
--   （失敗しても画像はアプリ側の簡易保存で送れます）
DO $$
BEGIN
  INSERT INTO storage.buckets (id, name, public)
  VALUES ('rtalk-media', 'rtalk-media', true)
  ON CONFLICT (id) DO NOTHING;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'storage bucket はスキップしました: %', SQLERRM;
END $$;

DO $$
BEGIN
  DROP POLICY IF EXISTS "rtalk_media_anon_select" ON storage.objects;
  DROP POLICY IF EXISTS "rtalk_media_anon_insert" ON storage.objects;
  CREATE POLICY "rtalk_media_anon_select" ON storage.objects
    FOR SELECT USING (bucket_id = 'rtalk-media');
  CREATE POLICY "rtalk_media_anon_insert" ON storage.objects
    FOR INSERT WITH CHECK (bucket_id = 'rtalk-media');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'storage policy はスキップしました: %', SQLERRM;
END $$;

-- リアルタイム同期（全員の画面に即反映）
ALTER TABLE rtalk_users        REPLICA IDENTITY FULL;
ALTER TABLE rtalk_rooms        REPLICA IDENTITY FULL;
ALTER TABLE rtalk_messages     REPLICA IDENTITY FULL;
ALTER TABLE rtalk_reads        REPLICA IDENTITY FULL;
ALTER TABLE rtalk_broadcasts   REPLICA IDENTITY FULL;
ALTER TABLE rtalk_bug_reports  REPLICA IDENTITY FULL;
ALTER TABLE rtalk_room_members REPLICA IDENTITY FULL;
ALTER TABLE rtalk_notes        REPLICA IDENTITY FULL;
ALTER TABLE rtalk_albums       REPLICA IDENTITY FULL;
ALTER TABLE rtalk_album_photos REPLICA IDENTITY FULL;
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['rtalk_users','rtalk_rooms','rtalk_messages','rtalk_reads','rtalk_broadcasts','rtalk_bug_reports','rtalk_room_members','rtalk_notes','rtalk_albums','rtalk_album_photos'] LOOP
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND tablename=t) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %I', t);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'realtime設定はスキップしました(%): %', t, SQLERRM;
    END;
  END LOOP;
END $$;

-- RLS: デモ版のためログイン不要（anon）で読み書き
ALTER TABLE rtalk_users       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtalk_rooms       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtalk_messages    ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtalk_reads       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtalk_broadcasts  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtalk_bug_reports ENABLE ROW LEVEL SECURITY;

ALTER TABLE rtalk_room_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtalk_notes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtalk_albums       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtalk_album_photos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "rtalk_users_anon_all"        ON rtalk_users;
DROP POLICY IF EXISTS "rtalk_rooms_anon_all"        ON rtalk_rooms;
DROP POLICY IF EXISTS "rtalk_messages_anon_all"     ON rtalk_messages;
DROP POLICY IF EXISTS "rtalk_reads_anon_all"        ON rtalk_reads;
DROP POLICY IF EXISTS "rtalk_broadcasts_anon_all"   ON rtalk_broadcasts;
DROP POLICY IF EXISTS "rtalk_bug_reports_anon_all"  ON rtalk_bug_reports;
DROP POLICY IF EXISTS "rtalk_members_anon_all"      ON rtalk_room_members;
DROP POLICY IF EXISTS "rtalk_notes_anon_all"        ON rtalk_notes;
DROP POLICY IF EXISTS "rtalk_albums_anon_all"       ON rtalk_albums;
DROP POLICY IF EXISTS "rtalk_album_photos_anon_all" ON rtalk_album_photos;
CREATE POLICY "rtalk_users_anon_all"        ON rtalk_users        FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_rooms_anon_all"        ON rtalk_rooms        FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_messages_anon_all"     ON rtalk_messages     FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_reads_anon_all"        ON rtalk_reads        FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_broadcasts_anon_all"   ON rtalk_broadcasts   FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_bug_reports_anon_all"  ON rtalk_bug_reports  FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_members_anon_all"      ON rtalk_room_members FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_notes_anon_all"        ON rtalk_notes        FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_albums_anon_all"       ON rtalk_albums       FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "rtalk_album_photos_anon_all" ON rtalk_album_photos FOR ALL USING (true) WITH CHECK (true);

-- 「Success. No rows returned」でOK。
