alter policy reactions_select_pair on public.reactions
  using (
    from_user = auth.uid()
    or exists (
      select 1 from public.checkins
      where checkins.id = reactions.checkin_id
    )
  );
