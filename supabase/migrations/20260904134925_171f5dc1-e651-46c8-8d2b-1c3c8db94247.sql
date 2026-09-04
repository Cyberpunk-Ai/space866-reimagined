revoke execute on function public.set_updated_at() from public;
revoke execute on function public.handle_new_user() from public;
revoke execute on function public.posts_counts_sync() from public;
revoke execute on function public.likes_count_sync() from public;
revoke execute on function public.reposts_count_sync() from public;
revoke execute on function public.follows_count_sync() from public;
revoke execute on function public.has_role(uuid, public.app_role) from public;
grant execute on function public.has_role(uuid, public.app_role) to authenticated;