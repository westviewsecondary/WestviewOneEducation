-- OneEducation MIS: run this whole file in the NEW Supabase project's SQL Editor.
-- Project: naxoplmtweovwaiwvexe. It does not use or modify your website project.
BEGIN;
CREATE TABLE IF NOT EXISTS public.oe_staff_access (
 email text PRIMARY KEY CHECK (email=lower(email)),
 role text NOT NULL CHECK (role IN ('admin','teacher'))
);
INSERT INTO public.oe_staff_access(email,role)
VALUES ('masonsandersbussiness@gmail.com','admin') ON CONFLICT (email) DO NOTHING;
CREATE TABLE IF NOT EXISTS public.oe_workspace (
 id integer PRIMARY KEY DEFAULT 1 CHECK(id=1),
 data jsonb,
 revision bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.oe_workspace(id) VALUES(1) ON CONFLICT(id) DO NOTHING;
CREATE TABLE IF NOT EXISTS public.oe_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 actor uuid,
 email text,
 action text NOT NULL,
 revision bigint,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.oe_staff_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.oe_workspace ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.oe_audit ENABLE ROW LEVEL SECURITY;
-- No browser role has direct access. Only the checked functions below expose data.
REVOKE ALL ON public.oe_staff_access,public.oe_workspace,public.oe_audit FROM anon,authenticated;

CREATE OR REPLACE FUNCTION public.oe_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT a.role FROM public.oe_staff_access a
 JOIN auth.users u ON u.id=auth.uid() AND lower(u.email)=a.email
 WHERE u.email_confirmed_at IS NOT NULL
 LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.oe_get_state() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r text; d jsonb; rev bigint;
BEGIN
 r:=public.oe_role(); IF r IS NULL THEN RAISE EXCEPTION 'This verified account is not on the OneEducation staff list.'; END IF;
 SELECT data,revision INTO d,rev FROM public.oe_workspace WHERE id=1;
 IF r='teacher' AND d IS NOT NULL THEN
  d:=jsonb_set(d,'{students}',COALESCE((SELECT jsonb_agg(p-'loginCode') FROM jsonb_array_elements(d->'students') p),'[]'::jsonb));
 END IF;
 RETURN jsonb_build_object('data',d,'revision',rev,'role',r);
END; $$;

CREATE OR REPLACE FUNCTION public.oe_save_state(p_data jsonb,p_revision bigint,p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r text; old jsonb; rev bigint; nextdata jsonb; k text; item jsonb; pupil jsonb; duplicates integer;
BEGIN
 r:=public.oe_role(); IF r IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 SELECT data,revision INTO old,rev FROM public.oe_workspace WHERE id=1 FOR UPDATE;
 IF rev IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'REVISION_CONFLICT: another person saved changes. Refresh before trying again.'; END IF;
 IF jsonb_typeof(p_data)<>'object' OR octet_length(p_data::text)>15000000 THEN RAISE EXCEPTION 'Invalid or oversized school workspace.'; END IF;
 IF r='teacher' THEN
  IF old IS NULL THEN RAISE EXCEPTION 'An administrator must initialise the school.'; END IF;
  nextdata:=old;
  FOREACH k IN ARRAY ARRAY['attendance','points','incidents','removals','announcements','covers'] LOOP
   nextdata:=jsonb_set(nextdata,ARRAY[k],COALESCE(p_data->k,'[]'::jsonb));
  END LOOP;
 ELSE nextdata:=p_data;
 END IF;
 FOREACH k IN ARRAY ARRAY['students','tutors','classes','teachers','rooms','houses','attendance','points','incidents','removals','announcements','covers','closures','cycles','exams'] LOOP
  IF jsonb_typeof(nextdata->k) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid workspace array: %',k; END IF;
 END LOOP;
 IF COALESCE(nextdata#>>'{school,status}','') NOT IN ('open','closing','closed') THEN RAISE EXCEPTION 'Choose open, closing or closed.'; END IF;
 -- Unique credentials and pupil identifiers, never readable by anonymous users.
 SELECT count(*)-count(DISTINCT p->>'id') INTO duplicates FROM jsonb_array_elements(nextdata->'students') p;
 IF duplicates>0 THEN RAISE EXCEPTION 'Duplicate pupil identifier.'; END IF;
 SELECT count(*)-count(DISTINCT p->>'loginCode') INTO duplicates FROM jsonb_array_elements(nextdata->'students') p;
 IF duplicates>0 THEN RAISE EXCEPTION 'Duplicate student login code.'; END IF;
 SELECT count(*)-count(DISTINCT p->>'candidateNumber') INTO duplicates FROM jsonb_array_elements(nextdata->'students') p;
 IF duplicates>0 THEN RAISE EXCEPTION 'Duplicate candidate number.'; END IF;
 FOR pupil IN SELECT value FROM jsonb_array_elements(nextdata->'students') LOOP
  IF COALESCE(pupil->>'loginCode','') !~ '^[A-F0-9]{8}(-[A-F0-9]{8}){3}$' OR COALESCE(pupil->>'candidateNumber','') !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'Invalid student codes.'; END IF;
  IF (pupil->>'year')::int NOT BETWEEN 7 AND 11 THEN RAISE EXCEPTION 'Invalid year group.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(nextdata->'tutors') t WHERE t->>'id'=pupil->>'tutorId' AND t->>'year'=pupil->>'year') THEN RAISE EXCEPTION 'Pupil tutor group must match their year.'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(pupil->'classIds') cid WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(nextdata->'classes') c WHERE c->>'id'=cid AND c->>'year'=pupil->>'year')) THEN RAISE EXCEPTION 'Pupil class must belong to their year.'; END IF;
 END LOOP;
 -- The closure rule is enforced in the database, even if somebody bypasses the UI.
 FOR item IN SELECT value FROM jsonb_array_elements(nextdata->'attendance') LOOP
  IF NOT COALESCE(old->'attendance','[]'::jsonb) @> jsonb_build_array(item) THEN
   IF nextdata#>>'{school,status}'<>'open' OR EXISTS (SELECT 1 FROM jsonb_array_elements(nextdata->'closures') c WHERE item->>'date' BETWEEN c->>'start' AND c->>'end' AND c->>'status'<>'open') THEN RAISE EXCEPTION 'Attendance is locked while school is closed or closing.'; END IF;
   IF COALESCE(item->>'mark','') NOT IN ('present','absent','late','ill','authorised','medical','removed') OR (item->>'period')::int NOT BETWEEN 0 AND 5 THEN RAISE EXCEPTION 'Invalid attendance mark.'; END IF;
   IF extract(isodow FROM (item->>'date')::date)>5 THEN RAISE EXCEPTION 'No attendance registers at weekends.'; END IF;
   IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(nextdata->'students') p WHERE p->>'id'=item->>'studentId' AND ((p->'classIds') ? (item->>'classId') OR (p->>'tutorId'=item->>'classId' AND item->>'period'='0'))) THEN RAISE EXCEPTION 'Pupil does not belong to this register.'; END IF;
  END IF;
 END LOOP;
 UPDATE public.oe_workspace SET data=nextdata,revision=revision+1,updated_at=now() WHERE id=1;
 INSERT INTO public.oe_audit(actor,email,action,revision) VALUES(auth.uid(),auth.jwt()->>'email',left(COALESCE(p_action,'Saved changes'),300),rev+1);
 RETURN public.oe_get_state();
END; $$;

CREATE OR REPLACE FUNCTION public.oe_student_portal(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d jsonb; p jsonb; code text; courses jsonb; notices jsonb;
BEGIN
 code:=upper(regexp_replace(COALESCE(p_code,''),'[-[:space:]]','','g'));
 IF length(code)<>32 OR code !~ '^[A-F0-9]{32}$' THEN RAISE EXCEPTION 'That login code was not recognised.'; END IF;
 SELECT data INTO d FROM public.oe_workspace WHERE id=1;
 SELECT value INTO p FROM jsonb_array_elements(COALESCE(d->'students','[]'::jsonb))
 WHERE replace(value->>'loginCode','-','')=code AND COALESCE((value->>'archived')::boolean,false)=false LIMIT 1;
 IF p IS NULL THEN RAISE EXCEPTION 'That login code was not recognised.'; END IF;
 SELECT COALESCE(jsonb_agg(c),'[]'::jsonb) INTO courses FROM jsonb_array_elements(d->'classes') c WHERE (p->'classIds') ? (c->>'id');
 SELECT COALESCE(jsonb_agg(n),'[]'::jsonb) INTO notices FROM jsonb_array_elements(d->'announcements') n WHERE n->>'scope'='school' OR (n->>'scope'='tutor' AND n->>'groupId'=p->>'tutorId') OR (n->>'scope'='class' AND (p->'classIds') ? (n->>'groupId'));
 -- Return one pupil only; no staff credentials, school roster or unrelated records.
 RETURN jsonb_build_object(
  'student',p-'loginCode','school',d->'school','classes',courses,'rooms',d->'rooms',
  'teachers',COALESCE((SELECT jsonb_agg(t) FROM jsonb_array_elements(d->'teachers') t WHERE EXISTS(SELECT 1 FROM jsonb_array_elements(courses) c WHERE c->>'teacherId'=t->>'id') OR EXISTS(SELECT 1 FROM jsonb_array_elements(d->'covers') cv WHERE cv->>'teacherId'=t->>'id' AND (p->'classIds') ? (cv->>'classId'))),'[]'::jsonb),
  'tutors',COALESCE((SELECT jsonb_agg(t) FROM jsonb_array_elements(d->'tutors') t WHERE t->>'id'=p->>'tutorId'),'[]'::jsonb),
  'exams',COALESCE((SELECT jsonb_agg(e) FROM jsonb_array_elements(d->'exams') e WHERE (p->'classIds') ? (e->>'classId')),'[]'::jsonb),
  'covers',COALESCE((SELECT jsonb_agg(c) FROM jsonb_array_elements(d->'covers') c WHERE (p->'classIds') ? (c->>'classId')),'[]'::jsonb),
  'removals',COALESCE((SELECT jsonb_agg(r-'reason') FROM jsonb_array_elements(d->'removals') r WHERE r->>'studentId'=p->>'id'),'[]'::jsonb),
  'closures',d->'closures','announcements',notices
 );
END; $$;

CREATE OR REPLACE FUNCTION public.oe_staff_list() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF public.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;
RETURN COALESCE((SELECT jsonb_agg(a ORDER BY a.email) FROM public.oe_staff_access a),'[]'::jsonb); END; $$;
CREATE OR REPLACE FUNCTION public.oe_set_staff(p_email text,p_role text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF public.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;
 IF lower(trim(p_email))='masonsandersbussiness@gmail.com' THEN RAISE EXCEPTION 'The owner account remains an administrator.'; END IF;
 IF p_role NOT IN ('teacher','admin','remove') OR p_email NOT LIKE '%@%.%' THEN RAISE EXCEPTION 'Enter a valid email and role.'; END IF;
 IF p_role='remove' THEN DELETE FROM public.oe_staff_access WHERE email=lower(trim(p_email));
 ELSE INSERT INTO public.oe_staff_access(email,role) VALUES(lower(trim(p_email)),p_role) ON CONFLICT(email) DO UPDATE SET role=excluded.role; END IF;
 INSERT INTO public.oe_audit(actor,email,action) VALUES(auth.uid(),auth.jwt()->>'email','Staff access: '||lower(trim(p_email))||' / '||p_role);
END; $$;
CREATE OR REPLACE FUNCTION public.oe_audit_log() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF public.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;
RETURN COALESCE((SELECT jsonb_agg(x) FROM (SELECT * FROM public.oe_audit ORDER BY id DESC LIMIT 150)x),'[]'::jsonb); END; $$;

REVOKE ALL ON FUNCTION public.oe_role(),public.oe_get_state(),public.oe_save_state(jsonb,bigint,text),public.oe_student_portal(text),public.oe_staff_list(),public.oe_set_staff(text,text),public.oe_audit_log() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.oe_role(),public.oe_get_state(),public.oe_save_state(jsonb,bigint,text),public.oe_staff_list(),public.oe_set_staff(text,text),public.oe_audit_log() TO authenticated;
GRANT EXECUTE ON FUNCTION public.oe_student_portal(text) TO anon,authenticated;
COMMIT;
SELECT 'OneEducation database ready. Create the owner user in Authentication, then sign in on index.html.' AS setup_status;
