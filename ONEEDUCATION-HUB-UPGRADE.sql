-- Existing schools: run this file once after the original setup.
-- New schools: run ONEEDUCATION-SETUP.sql, then this file.
-- Non-destructive, repeatable upgrade. Existing MIS data stays in oe_workspace.
BEGIN;
CREATE TABLE IF NOT EXISTS public.oe_hub_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL CHECK(kind IN ('staff','homework','report','evening','activity','revision')),
 data jsonb NOT NULL, revision integer NOT NULL DEFAULT 1, created_by uuid, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.oe_hub_actions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL CHECK(kind IN ('submission','ticket','booking','enrolment','plan')),
 student_id text, item_id uuid REFERENCES public.oe_hub_items(id), data jsonb NOT NULL,
 revision integer NOT NULL DEFAULT 1, created_by uuid, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS oe_hub_student_item ON public.oe_hub_actions(kind,student_id,item_id) WHERE item_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS public.oe_portal_settings (
 id integer PRIMARY KEY CHECK(id=1),data jsonb NOT NULL DEFAULT '{"global":{},"students":{}}',revision integer NOT NULL DEFAULT 1
);
INSERT INTO public.oe_portal_settings(id) VALUES(1) ON CONFLICT DO NOTHING;
ALTER TABLE public.oe_hub_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.oe_hub_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.oe_portal_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.oe_hub_items,public.oe_hub_actions,public.oe_portal_settings FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.oe_hub_student(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb; code text;
BEGIN
 code:=upper(regexp_replace(coalesce(p_code,''),'[-[:space:]]','','g'));
 IF code !~ '^[A-F0-9]{32}$' THEN RAISE EXCEPTION 'Student code not recognised.'; END IF;
 SELECT s INTO p FROM public.oe_workspace w CROSS JOIN LATERAL jsonb_array_elements(w.data->'students') s
 WHERE w.id=1 AND replace(s->>'loginCode','-','')=code AND NOT coalesce((s->>'archived')::boolean,false);
 IF p IS NULL THEN RAISE EXCEPTION 'Student code not recognised.'; END IF;
 RETURN p;
END; $$;

CREATE OR REPLACE FUNCTION public.oe_portal_permissions(p_student text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT '{"timetable":true,"classes":true,"exams":true,"notices":true,"homework":true,"reports":true,"evenings":true,"helpdesk":true,"activities":true,"revision":true}'::jsonb
 ||coalesce(data->'global','{}'::jsonb)||coalesce(data->'students'->p_student,'{}'::jsonb)
 FROM public.oe_portal_settings WHERE id=1;
$$;
CREATE OR REPLACE FUNCTION public.oe_hub_target(d jsonb,p jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE coalesce(d->>'targetType','school') WHEN 'school' THEN true WHEN 'year' THEN d->>'targetId'=p->>'year'
 WHEN 'tutor' THEN d->>'targetId'=p->>'tutorId' WHEN 'class' THEN (p->'classIds') ? (d->>'targetId') ELSE false END;
$$;
CREATE OR REPLACE FUNCTION public.oe_hub_validate_file(d jsonb) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE f jsonb; bytes bytea;
BEGIN
 f:=d->'attachment'; IF f IS NULL OR f='null'::jsonb THEN RETURN; END IF;
 IF jsonb_typeof(f)<>'object' OR length(coalesce(f->>'name','')) NOT BETWEEN 1 AND 180 THEN RAISE EXCEPTION 'Invalid attachment name.'; END IF;
 IF coalesce(f->>'name','') !~* '\.(pdf|png|jpg|jpeg|txt|docx|xlsx|pptx|csv)$' THEN RAISE EXCEPTION 'Use a PDF, image, text, CSV or Office attachment.'; END IF;
 bytes:=decode(f->>'base64','base64');
 IF bytes IS NULL OR octet_length(bytes)>2097152 THEN RAISE EXCEPTION 'Attachments must be 2 MB or smaller.'; END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.oe_hub_staff() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r text;
BEGIN
 r:=public.oe_role(); IF r IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 RETURN jsonb_build_object('items',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY updated_at DESC) FROM public.oe_hub_items i),'[]'::jsonb),
 'actions',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY updated_at DESC) FROM public.oe_hub_actions a),'[]'::jsonb),
 'settings',CASE WHEN r='admin' THEN (SELECT to_jsonb(s) FROM public.oe_portal_settings s WHERE id=1) ELSE NULL END,'role',r);
END; $$;

CREATE OR REPLACE FUNCTION public.oe_hub_settings_save(p_data jsonb,p_revision integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE rev integer; rules jsonb; kv record; student_rule record;
BEGIN
 IF public.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Only administrators can change portal visibility.'; END IF;
 SELECT revision INTO rev FROM public.oe_portal_settings WHERE id=1 FOR UPDATE;
 IF rev<>p_revision THEN RAISE EXCEPTION 'Settings changed elsewhere. Reload before saving.'; END IF;
 IF jsonb_typeof(p_data->'global') IS DISTINCT FROM 'object' OR jsonb_typeof(p_data->'students') IS DISTINCT FROM 'object' OR octet_length(p_data::text)>500000 THEN RAISE EXCEPTION 'Invalid portal settings.'; END IF;
 FOR rules IN SELECT p_data->'global' UNION ALL SELECT value FROM jsonb_each(p_data->'students') LOOP
  IF jsonb_typeof(rules)<>'object' THEN RAISE EXCEPTION 'Invalid student override.'; END IF;
  FOR kv IN SELECT * FROM jsonb_each(rules) LOOP
   IF kv.key NOT IN ('timetable','classes','exams','notices','homework','reports','evenings','helpdesk','activities','revision') OR jsonb_typeof(kv.value)<>'boolean' THEN RAISE EXCEPTION 'Unknown portal section or invalid visibility value.'; END IF;
  END LOOP;
 END LOOP;
 FOR student_rule IN SELECT key FROM jsonb_each(p_data->'students') LOOP
  IF NOT EXISTS(SELECT 1 FROM public.oe_workspace w CROSS JOIN LATERAL jsonb_array_elements(w.data->'students') s WHERE w.id=1 AND s->>'id'=student_rule.key) THEN RAISE EXCEPTION 'An override refers to an unknown student.'; END IF;
 END LOOP;
 UPDATE public.oe_portal_settings SET data=p_data,revision=revision+1 WHERE id=1;
 INSERT INTO public.oe_audit(actor,email,action,revision) SELECT auth.uid(),auth.jwt()->>'email','Changed student portal visibility',revision FROM public.oe_workspace WHERE id=1;
 RETURN (SELECT to_jsonb(s) FROM public.oe_portal_settings s WHERE id=1);
END; $$;

CREATE OR REPLACE FUNCTION public.oe_hub_item_save(p_kind text,p_data jsonb,p_id uuid DEFAULT NULL,p_revision integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE row public.oe_hub_items; w jsonb; pupil jsonb; st timestamp; en timestamp;
BEGIN
 IF public.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 SELECT data INTO w FROM public.oe_workspace WHERE id=1;
 IF w IS NULL THEN RAISE EXCEPTION 'Save the main school workspace first.'; END IF;
 IF p_kind NOT IN ('staff','homework','report','evening','activity','revision') OR jsonb_typeof(p_data)<>'object' OR octet_length(p_data::text)>3000000 THEN RAISE EXCEPTION 'Invalid hub record.'; END IF;
 IF length(trim(coalesce(p_data->>'title',''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Enter a title up to 160 characters.'; END IF;
 IF length(coalesce(p_data->>'body',''))>12000 THEN RAISE EXCEPTION 'Message is too long.'; END IF;
 IF coalesce(p_data->>'url','')<>'' AND p_data->>'url' !~ '^https?://[^[:space:]]+$' THEN RAISE EXCEPTION 'Resource links must start with https:// or http://.'; END IF;
 PERFORM public.oe_hub_validate_file(p_data);
 IF jsonb_typeof(p_data->'published') IS DISTINCT FROM 'boolean' OR jsonb_typeof(p_data->'archived') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Choose publication status.'; END IF;
 IF p_kind IN ('homework','activity','revision') THEN
  IF coalesce(p_data->>'targetType','') NOT IN ('school','year','tutor','class') THEN RAISE EXCEPTION 'Choose a target audience.'; END IF;
  IF p_data->>'targetType'='year' AND coalesce(p_data->>'targetId','') NOT IN ('7','8','9','10','11') THEN RAISE EXCEPTION 'Choose Year 7–11.'; END IF;
  IF p_data->>'targetType'='class' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(w->'classes') c WHERE c->>'id'=p_data->>'targetId') THEN RAISE EXCEPTION 'Choose an existing class.'; END IF;
  IF p_data->>'targetType'='tutor' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(w->'tutors') t WHERE t->>'id'=p_data->>'targetId') THEN RAISE EXCEPTION 'Choose an existing tutor group.'; END IF;
 END IF;
 IF p_kind='homework' AND (p_data->>'due')::date IS NULL THEN RAISE EXCEPTION 'Choose a due date.'; END IF;
 IF p_kind='report' THEN
  SELECT s INTO pupil FROM jsonb_array_elements(w->'students') s WHERE s->>'id'=p_data->>'studentId' AND NOT coalesce((s->>'archived')::boolean,false);
  IF pupil IS NULL OR length(trim(coalesce(p_data->>'term','')))=0 OR length(trim(coalesce(p_data->>'subject','')))=0 THEN RAISE EXCEPTION 'Choose a student, subject and reporting term.'; END IF;
 END IF;
 IF p_kind='evening' THEN
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(w->'teachers') t WHERE t->>'id'=p_data->>'teacherId') THEN RAISE EXCEPTION 'Choose a teacher.'; END IF;
  st:=(p_data->>'date')::date+(p_data->>'start')::time; en:=(p_data->>'date')::date+(p_data->>'end')::time;
  IF st IS NULL OR en IS NULL OR en<=st OR en-st>interval '60 minutes' THEN RAISE EXCEPTION 'Use a valid appointment of up to 60 minutes.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('evening:'||(p_data->>'teacherId')));
  IF EXISTS(SELECT 1 FROM public.oe_hub_items i WHERE i.kind='evening' AND i.id IS DISTINCT FROM p_id AND NOT (i.data->>'archived')::boolean AND i.data->>'teacherId'=p_data->>'teacherId'
   AND (i.data->>'date')::date+(i.data->>'start')::time<en AND (i.data->>'date')::date+(i.data->>'end')::time>st) THEN RAISE EXCEPTION 'This teacher already has an overlapping appointment slot.'; END IF;
 END IF;
 IF p_kind='activity' AND (coalesce((p_data->>'capacity')::int,0) NOT BETWEEN 1 AND 500 OR (p_data->>'date')::date IS NULL) THEN RAISE EXCEPTION 'Choose a date and capacity between 1 and 500.'; END IF;
 IF p_id IS NOT NULL THEN
  SELECT * INTO row FROM public.oe_hub_items WHERE id=p_id FOR UPDATE;
  IF row.id IS NULL OR row.revision<>p_revision OR row.kind<>p_kind THEN RAISE EXCEPTION 'Record changed or is unavailable. Reload first.'; END IF;
  IF p_kind IN ('evening','activity') AND EXISTS(SELECT 1 FROM public.oe_hub_actions a WHERE a.item_id=p_id AND a.data->>'status'<>'cancelled') THEN
   IF p_data->>'archived'='true' OR p_data->>'date' IS DISTINCT FROM row.data->>'date' OR p_data->>'start' IS DISTINCT FROM row.data->>'start' OR p_data->>'end' IS DISTINCT FROM row.data->>'end' OR p_data->>'teacherId' IS DISTINCT FROM row.data->>'teacherId' THEN RAISE EXCEPTION 'Cancel active bookings or sign-ups before changing the date, teacher or archiving.'; END IF;
   IF p_kind='activity' AND (p_data->>'capacity')::int<(SELECT count(*) FROM public.oe_hub_actions WHERE item_id=p_id AND data->>'status'<>'cancelled') THEN RAISE EXCEPTION 'Capacity cannot be below current sign-ups.'; END IF;
  END IF;
  UPDATE public.oe_hub_items SET data=p_data,revision=revision+1,updated_at=now() WHERE id=p_id RETURNING * INTO row;
 ELSE
  INSERT INTO public.oe_hub_items(kind,data,created_by) VALUES(p_kind,p_data,auth.uid()) RETURNING * INTO row;
 END IF;
 INSERT INTO public.oe_audit(actor,email,action,revision) SELECT auth.uid(),auth.jwt()->>'email','Saved hub '||p_kind||': '||(p_data->>'title'),revision FROM public.oe_workspace WHERE id=1;
 RETURN to_jsonb(row);
END; $$;

CREATE OR REPLACE FUNCTION public.oe_hub_portal_data(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb; perms jsonb; w jsonb; items jsonb; actions jsonb;
BEGIN
 p:=public.oe_hub_student(p_code); perms:=public.oe_portal_permissions(p->>'id');
 SELECT data INTO w FROM public.oe_workspace WHERE id=1;
 SELECT coalesce(jsonb_agg(to_jsonb(i)-'created_by' ORDER BY updated_at DESC),'[]'::jsonb) INTO items FROM public.oe_hub_items i
 WHERE (i.data->>'published')::boolean AND NOT (i.data->>'archived')::boolean AND CASE i.kind
  WHEN 'homework' THEN (perms->>'homework')::boolean AND public.oe_hub_target(i.data,p)
  WHEN 'revision' THEN (perms->>'revision')::boolean AND public.oe_hub_target(i.data,p)
  WHEN 'activity' THEN (perms->>'activities')::boolean AND public.oe_hub_target(i.data,p)
  WHEN 'report' THEN (perms->>'reports')::boolean AND i.data->>'studentId'=p->>'id'
  WHEN 'evening' THEN (perms->>'evenings')::boolean AND EXISTS(SELECT 1 FROM jsonb_array_elements(w->'classes') c WHERE (p->'classIds') ? (c->>'id') AND c->>'teacherId'=i.data->>'teacherId')
  ELSE false END;
 SELECT coalesce(jsonb_agg(to_jsonb(a)-'created_by' ORDER BY updated_at DESC),'[]'::jsonb) INTO actions FROM public.oe_hub_actions a
 WHERE a.student_id=p->>'id' AND CASE a.kind WHEN 'ticket' THEN (perms->>'helpdesk')::boolean ELSE EXISTS(SELECT 1 FROM jsonb_array_elements(items) i WHERE i->>'id'=a.item_id::text) END;
 -- Capacity availability contains no other pupil's identity or booking details.
 SELECT coalesce(jsonb_agg(i||jsonb_build_object('available',greatest(0,CASE WHEN i->>'kind'='evening' THEN 1 ELSE coalesce((i#>>'{data,capacity}')::int,0) END-(SELECT count(*)::int FROM public.oe_hub_actions a WHERE a.item_id::text=i->>'id' AND a.data->>'status'<>'cancelled')))),'[]'::jsonb)
 INTO items FROM jsonb_array_elements(items) i;
 RETURN jsonb_build_object('items',items,'actions',actions,'permissions',perms);
END; $$;

CREATE OR REPLACE FUNCTION public.oe_hub_student_action(p_code text,p_kind text,p_data jsonb,p_item uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb; perms jsonb; item public.oe_hub_items; row public.oe_hub_actions; old public.oe_hub_actions; allowed boolean; n integer; st timestamp; en timestamp; status_value text; fresh jsonb;
BEGIN
 p:=public.oe_hub_student(p_code);perms:=public.oe_portal_permissions(p->>'id');
 IF p_kind NOT IN ('submission','ticket','booking','enrolment','plan') OR jsonb_typeof(p_data)<>'object' OR octet_length(p_data::text)>3000000 THEN RAISE EXCEPTION 'Invalid request.'; END IF;
 allowed:=(perms->>CASE p_kind WHEN 'submission' THEN 'homework' WHEN 'ticket' THEN 'helpdesk' WHEN 'booking' THEN 'evenings' WHEN 'plan' THEN 'revision' ELSE 'activities' END)::boolean;
 IF NOT allowed THEN RAISE EXCEPTION 'Your school has hidden this portal section.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtext(p->>'id'));
 IF p_kind='ticket' AND p_item IS NOT NULL THEN RAISE EXCEPTION 'Tickets cannot be linked to another item.'; END IF;
 IF p_kind<>'ticket' THEN
  SELECT * INTO item FROM public.oe_hub_items WHERE id=p_item FOR UPDATE;
  IF item.id IS NULL OR item.kind<>(CASE p_kind WHEN 'submission' THEN 'homework' WHEN 'booking' THEN 'evening' WHEN 'plan' THEN 'revision' ELSE 'activity' END) OR NOT (item.data->>'published')::boolean OR (item.data->>'archived')::boolean THEN RAISE EXCEPTION 'This item is unavailable.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.oe_hub_portal_data(p_code)->'items') i WHERE i->>'id'=p_item::text) THEN RAISE EXCEPTION 'This item is not available to your student.'; END IF;
  SELECT * INTO old FROM public.oe_hub_actions WHERE student_id=p->>'id' AND item_id=p_item AND kind=p_kind FOR UPDATE;
 END IF;
 IF p_kind='submission' THEN
  IF length(trim(coalesce(p_data->>'body','')))=0 AND (p_data->'attachment' IS NULL OR p_data->'attachment'='null'::jsonb) THEN RAISE EXCEPTION 'Enter your answer or attach a file.'; END IF;
  PERFORM public.oe_hub_validate_file(p_data);
  fresh:=jsonb_build_object('body',left(coalesce(p_data->>'body',''),20000),'attachment',p_data->'attachment','status','submitted','submittedAt',now(),'late',(now() AT TIME ZONE 'Europe/London')::date>(item.data->>'due')::date);
 ELSIF p_kind='plan' THEN
  IF (p_data->>'targetDate')::date IS NULL THEN RAISE EXCEPTION 'Choose a revision date.'; END IF;
  fresh:=jsonb_build_object('status',CASE WHEN p_data->>'status'='complete' THEN 'complete' ELSE 'planned' END,'targetDate',p_data->>'targetDate','body',left(coalesce(p_data->>'body',''),4000),'submittedAt',now());
 ELSIF p_kind='ticket' THEN
  IF length(trim(coalesce(p_data->>'title','')))=0 OR length(trim(coalesce(p_data->>'body','')))=0 OR p_data->>'category' NOT IN ('IT','Lost property','Room request','General') THEN RAISE EXCEPTION 'Add a title, category and message.'; END IF;
  fresh:=jsonb_build_object('title',left(p_data->>'title',160),'body',left(p_data->>'body',10000),'category',p_data->>'category','location',left(coalesce(p_data->>'location',''),160),'status','open','submittedAt',now());
 ELSIF p_kind='booking' THEN
  st:=(item.data->>'date')::date+(item.data->>'start')::time;en:=(item.data->>'date')::date+(item.data->>'end')::time;
  IF st<now() AT TIME ZONE 'Europe/London' THEN RAISE EXCEPTION 'This appointment has already started.'; END IF;
  status_value:=CASE WHEN p_data->>'status'='cancelled' THEN 'cancelled' ELSE 'booked' END;
  IF status_value='booked' THEN
   IF EXISTS(SELECT 1 FROM public.oe_hub_actions WHERE item_id=p_item AND kind='booking' AND student_id<>p->>'id' AND data->>'status'<>'cancelled') THEN RAISE EXCEPTION 'This slot has just been booked. Choose another.'; END IF;
   IF EXISTS(SELECT 1 FROM public.oe_hub_actions a JOIN public.oe_hub_items i ON i.id=a.item_id WHERE a.student_id=p->>'id' AND a.kind='booking' AND a.item_id<>p_item AND a.data->>'status'<>'cancelled'
    AND (((i.data->>'date')::date+(i.data->>'start')::time<en AND (i.data->>'date')::date+(i.data->>'end')::time>st) OR (i.data->>'teacherId'=item.data->>'teacherId' AND i.data->>'date'=item.data->>'date'))) THEN RAISE EXCEPTION 'You already have an overlapping appointment or a booking with this teacher that day.'; END IF;
   IF length(trim(coalesce(p_data->>'parentName','')))=0 THEN RAISE EXCEPTION 'Enter the attending adult’s name.'; END IF;
  END IF;
  fresh:=jsonb_build_object('status',status_value,'parentName',left(coalesce(p_data->>'parentName',old.data->>'parentName'),160),'submittedAt',now());
 ELSE
  status_value:=CASE WHEN p_data->>'status'='cancelled' THEN 'cancelled' ELSE 'pending' END;
  IF status_value='pending' THEN
   IF (item.data->>'date')::date<(now() AT TIME ZONE 'Europe/London')::date THEN RAISE EXCEPTION 'This activity has already taken place.'; END IF;
   SELECT count(*) INTO n FROM public.oe_hub_actions WHERE item_id=p_item AND student_id<>p->>'id' AND data->>'status'<>'cancelled';
   IF n>=(item.data->>'capacity')::int THEN RAISE EXCEPTION 'This activity is full.'; END IF;
   IF coalesce((item.data->>'requiresConsent')::boolean,false) AND (p_data->>'consent' IS DISTINCT FROM 'true' OR length(trim(coalesce(p_data->>'parentName','')))=0) THEN RAISE EXCEPTION 'Parent/guardian name and consent declaration are required.'; END IF;
   IF old.data->>'status'='approved' THEN status_value:='approved'; END IF;
  END IF;
  fresh:=jsonb_build_object('status',status_value,'parentName',left(coalesce(p_data->>'parentName',old.data->>'parentName'),160),'consent',coalesce((p_data->>'consent')::boolean,false),'submittedAt',now());
 END IF;
 IF old.id IS NULL THEN INSERT INTO public.oe_hub_actions(kind,student_id,item_id,data) VALUES(p_kind,p->>'id',p_item,fresh) RETURNING * INTO row;
 ELSE UPDATE public.oe_hub_actions SET data=fresh,revision=revision+1,updated_at=now() WHERE id=old.id RETURNING * INTO row; END IF;
 RETURN to_jsonb(row)-'created_by';
END; $$;

CREATE OR REPLACE FUNCTION public.oe_hub_review(p_id uuid,p_revision integer,p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE row public.oe_hub_actions; allowed text[];
BEGIN
 IF public.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 SELECT * INTO row FROM public.oe_hub_actions WHERE id=p_id FOR UPDATE;
 IF row.id IS NULL OR row.revision<>p_revision THEN RAISE EXCEPTION 'Record changed. Reload before reviewing.'; END IF;
 allowed:=CASE row.kind WHEN 'submission' THEN ARRAY['submitted','reviewed'] WHEN 'plan' THEN ARRAY['planned','complete'] WHEN 'ticket' THEN ARRAY['open','in progress','resolved'] WHEN 'enrolment' THEN ARRAY['pending','approved','cancelled'] ELSE ARRAY['booked','cancelled'] END;
 IF p_data->>'status' IS NULL OR NOT (p_data->>'status'=ANY(allowed)) THEN RAISE EXCEPTION 'Choose a valid status.'; END IF;
 -- Staff may cancel a booking/enrolment here; reactivation goes through capacity checks.
 IF row.data->>'status'='cancelled' AND p_data->>'status'<>'cancelled' THEN RAISE EXCEPTION 'The family must sign up again so capacity can be checked.'; END IF;
 UPDATE public.oe_hub_actions SET data=data||jsonb_build_object('status',p_data->>'status','feedback',left(coalesce(p_data->>'feedback',''),10000),'grade',left(coalesce(p_data->>'grade',''),40),'reviewedAt',now()),revision=revision+1,updated_at=now() WHERE id=p_id RETURNING * INTO row;
 INSERT INTO public.oe_audit(actor,email,action,revision) SELECT auth.uid(),auth.jwt()->>'email','Reviewed hub '||row.kind,revision FROM public.oe_workspace WHERE id=1;
 RETURN to_jsonb(row);
END; $$;
CREATE OR REPLACE FUNCTION public.oe_hub_staff_ticket(p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE row public.oe_hub_actions;
BEGIN
 IF public.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 IF length(trim(coalesce(p_data->>'title','')))=0 OR length(trim(coalesce(p_data->>'body','')))=0 THEN RAISE EXCEPTION 'Enter a title and message.'; END IF;
 INSERT INTO public.oe_hub_actions(kind,data,created_by) VALUES('ticket',jsonb_build_object('title',left(p_data->>'title',160),'body',left(p_data->>'body',10000),'category',left(coalesce(p_data->>'category','General'),50),'location',left(coalesce(p_data->>'location',''),160),'requester',auth.jwt()->>'email','status','open','submittedAt',now()),auth.uid()) RETURNING * INTO row;
 RETURN to_jsonb(row);
END; $$;

-- Preserve the previous RPC internally, then enforce visibility on its public name.
DO $$ BEGIN
 IF to_regprocedure('public.oe_student_portal_v1_internal(text)') IS NULL THEN
  ALTER FUNCTION public.oe_student_portal(text) RENAME TO oe_student_portal_v1_internal;
 END IF;
END; $$;
REVOKE ALL ON FUNCTION public.oe_student_portal_v1_internal(text) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.oe_student_portal(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE d jsonb; perms jsonb; courses jsonb;
BEGIN
 d:=public.oe_student_portal_v1_internal(p_code);perms:=public.oe_portal_permissions(d#>>'{student,id}');
 IF NOT (perms->>'timetable')::boolean THEN
  d:=d||jsonb_build_object('covers','[]'::jsonb,'removals','[]'::jsonb);
 END IF;
 SELECT coalesce(jsonb_agg(CASE WHEN (perms->>'timetable')::boolean THEN c ELSE c-'meetings' END),'[]'::jsonb) INTO courses FROM jsonb_array_elements(d->'classes') c
 WHERE (perms->>'timetable')::boolean OR (perms->>'classes')::boolean;
 d:=d||jsonb_build_object('classes',courses);
 IF NOT (perms->>'exams')::boolean THEN d:=d||jsonb_build_object('exams','[]'::jsonb); END IF;
 IF NOT (perms->>'exams')::boolean THEN d:=jsonb_set(d,'{announcements}',coalesce((SELECT jsonb_agg(n) FROM jsonb_array_elements(d->'announcements') n WHERE NOT coalesce((n->>'sourceExam')::boolean,false)),'[]'::jsonb)); END IF;
 IF NOT (perms->>'timetable')::boolean AND NOT (perms->>'classes')::boolean AND NOT (perms->>'evenings')::boolean THEN d:=d||jsonb_build_object('teachers','[]'::jsonb); END IF;
 IF NOT (perms->>'notices')::boolean THEN d:=d||jsonb_build_object('announcements','[]'::jsonb); END IF;
 IF NOT (perms->>'timetable')::boolean AND NOT (perms->>'exams')::boolean THEN d:=d||jsonb_build_object('rooms','[]'::jsonb); END IF;
 RETURN d||jsonb_build_object('permissions',perms,'hub',public.oe_hub_portal_data(p_code));
END; $$;

REVOKE ALL ON FUNCTION public.oe_hub_student(text),public.oe_portal_permissions(text),public.oe_hub_target(jsonb,jsonb),public.oe_hub_validate_file(jsonb),public.oe_hub_staff(),public.oe_hub_settings_save(jsonb,integer),public.oe_hub_item_save(text,jsonb,uuid,integer),public.oe_hub_portal_data(text),public.oe_hub_student_action(text,text,jsonb,uuid),public.oe_hub_review(uuid,integer,jsonb),public.oe_hub_staff_ticket(jsonb),public.oe_student_portal(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.oe_hub_staff(),public.oe_hub_settings_save(jsonb,integer),public.oe_hub_item_save(text,jsonb,uuid,integer),public.oe_hub_review(uuid,integer,jsonb),public.oe_hub_staff_ticket(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.oe_student_portal(text),public.oe_hub_student_action(text,text,jsonb,uuid) TO anon,authenticated;
COMMIT;



