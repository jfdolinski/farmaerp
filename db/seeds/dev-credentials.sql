-- Só em desenvolvimento e testes. A senha de exemplo é farmaerp-dev-123.
INSERT INTO user_credential (id, user_id, password_hash, must_change_password) VALUES
  ('019a0000-0000-7000-8000-00000000000b', '019a0000-0000-7000-8000-000000000008', '$argon2id$v=19$m=65536,t=3,p=4$oHLzCbMaOMPn68f79mWrMQ$rgneH0VnUbpjx6hyvOlqQbODY3TUx+1lYhksRvOQDYo', false),
  ('019a0000-0000-7000-8000-00000000000c', '019a0000-0000-7000-8000-000000000009', '$argon2id$v=19$m=65536,t=3,p=4$oHLzCbMaOMPn68f79mWrMQ$rgneH0VnUbpjx6hyvOlqQbODY3TUx+1lYhksRvOQDYo', false),
  ('019a0000-0000-7000-8000-000000000012', '019a0000-0000-7000-8000-00000000000d', '$argon2id$v=19$m=65536,t=3,p=4$oHLzCbMaOMPn68f79mWrMQ$rgneH0VnUbpjx6hyvOlqQbODY3TUx+1lYhksRvOQDYo', false)
ON CONFLICT (id) DO NOTHING;

-- Em desenvolvimento, o administrador de demonstração também administra a plataforma. Na homologação
-- e na produção, quem administra é o primeiro administrador do deploy (BOOTSTRAP_ADMIN_EMAIL).
INSERT INTO platform_admin (user_id)
SELECT '019a0000-0000-7000-8000-000000000008'::uuid
 WHERE NOT EXISTS (SELECT 1 FROM platform_admin WHERE user_id = '019a0000-0000-7000-8000-000000000008' AND deleted_at IS NULL);
