revoke execute on function public.set_updated_at() from anon, authenticated;
revoke execute on function public.handle_new_user() from anon, authenticated;
revoke execute on function public.posts_counts_sync() from anon, authenticated;
revoke execute on function public.likes_count_sync() from anon, authenticated;
revoke execute on function public.reposts_count_sync() from anon, authenticated;
revoke execute on function public.follows_count_sync() from anon, authenticated;
revoke execute on function public.has_role(uuid, public.app_role) from anon;