--
-- PostgreSQL database dump
--

-- Dumped from database version 11.16 (Ubuntu 11.16-1.pgdg18.04+1)
-- Dumped by pg_dump version 12.11 (Ubuntu 12.11-1.pgdg18.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: metric_helpers; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA metric_helpers;


ALTER SCHEMA metric_helpers OWNER TO postgres;

--
-- Name: user_management; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA user_management;


ALTER SCHEMA user_management OWNER TO postgres;

--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_stat_statements IS 'track execution statistics of all SQL statements executed';


--
-- Name: pg_stat_kcache; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_kcache WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_kcache; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_stat_kcache IS 'Kernel statistics gathering';


--
-- Name: set_user; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS set_user WITH SCHEMA public;


--
-- Name: EXTENSION set_user; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION set_user IS 'similar to SET ROLE but with added logging';


--
-- Name: group_namespace; Type: TYPE; Schema: public; Owner: hmsdsuser
--

CREATE TYPE public.group_namespace AS ENUM (
    'partition',
    'group'
);


ALTER TYPE public.group_namespace OWNER TO hmsdsuser;

--
-- Name: group_type; Type: TYPE; Schema: public; Owner: hmsdsuser
--

CREATE TYPE public.group_type AS ENUM (
    'partition',
    'exclusive',
    'shared'
);


ALTER TYPE public.group_type OWNER TO hmsdsuser;

--
-- Name: get_btree_bloat_approx(); Type: FUNCTION; Schema: metric_helpers; Owner: postgres
--

CREATE FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) RETURNS SETOF record
    LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
SELECT current_database(), nspname AS schemaname, tblname, idxname, bs*(relpages)::bigint AS real_size,
  bs*(relpages-est_pages)::bigint AS extra_size,
  100 * (relpages-est_pages)::float / relpages AS extra_ratio,
  fillfactor,
  CASE WHEN relpages > est_pages_ff
    THEN bs*(relpages-est_pages_ff)
    ELSE 0
  END AS bloat_size,
  100 * (relpages-est_pages_ff)::float / relpages AS bloat_ratio,
  is_na
  -- , 100-(pst).avg_leaf_density AS pst_avg_bloat, est_pages, index_tuple_hdr_bm, maxalign, pagehdr, nulldatawidth, nulldatahdrwidth, reltuples, relpages -- (DEBUG INFO)
FROM (
  SELECT coalesce(1 +
         ceil(reltuples/floor((bs-pageopqdata-pagehdr)/(4+nulldatahdrwidth)::float)), 0 -- ItemIdData size + computed avg size of a tuple (nulldatahdrwidth)
      ) AS est_pages,
      coalesce(1 +
         ceil(reltuples/floor((bs-pageopqdata-pagehdr)*fillfactor/(100*(4+nulldatahdrwidth)::float))), 0
      ) AS est_pages_ff,
      bs, nspname, tblname, idxname, relpages, fillfactor, is_na
      -- , pgstatindex(idxoid) AS pst, index_tuple_hdr_bm, maxalign, pagehdr, nulldatawidth, nulldatahdrwidth, reltuples -- (DEBUG INFO)
  FROM (
      SELECT maxalign, bs, nspname, tblname, idxname, reltuples, relpages, idxoid, fillfactor,
            ( index_tuple_hdr_bm +
                maxalign - CASE -- Add padding to the index tuple header to align on MAXALIGN
                  WHEN index_tuple_hdr_bm%maxalign = 0 THEN maxalign
                  ELSE index_tuple_hdr_bm%maxalign
                END
              + nulldatawidth + maxalign - CASE -- Add padding to the data to align on MAXALIGN
                  WHEN nulldatawidth = 0 THEN 0
                  WHEN nulldatawidth::integer%maxalign = 0 THEN maxalign
                  ELSE nulldatawidth::integer%maxalign
                END
            )::numeric AS nulldatahdrwidth, pagehdr, pageopqdata, is_na
            -- , index_tuple_hdr_bm, nulldatawidth -- (DEBUG INFO)
      FROM (
          SELECT n.nspname, ct.relname AS tblname, i.idxname, i.reltuples, i.relpages,
              i.idxoid, i.fillfactor, current_setting('block_size')::numeric AS bs,
              CASE -- MAXALIGN: 4 on 32bits, 8 on 64bits (and mingw32 ?)
                WHEN version() ~ 'mingw32' OR version() ~ '64-bit|x86_64|ppc64|ia64|amd64' THEN 8
                ELSE 4
              END AS maxalign,
              /* per page header, fixed size: 20 for 7.X, 24 for others */
              24 AS pagehdr,
              /* per page btree opaque data */
              16 AS pageopqdata,
              /* per tuple header: add IndexAttributeBitMapData if some cols are null-able */
              CASE WHEN max(coalesce(s.stanullfrac,0)) = 0
                  THEN 2 -- IndexTupleData size
                  ELSE 2 + (( 32 + 8 - 1 ) / 8) -- IndexTupleData size + IndexAttributeBitMapData size ( max num filed per index + 8 - 1 /8)
              END AS index_tuple_hdr_bm,
              /* data len: we remove null values save space using it fractionnal part from stats */
              sum( (1-coalesce(s.stanullfrac, 0)) * coalesce(s.stawidth, 1024)) AS nulldatawidth,
              max( CASE WHEN a.atttypid = 'pg_catalog.name'::regtype THEN 1 ELSE 0 END ) > 0 AS is_na
          FROM (
              SELECT idxname, reltuples, relpages, tbloid, idxoid, fillfactor,
                  CASE WHEN indkey[i]=0 THEN idxoid ELSE tbloid END AS att_rel,
                  CASE WHEN indkey[i]=0 THEN i ELSE indkey[i] END AS att_pos
              FROM (
                  SELECT idxname, reltuples, relpages, tbloid, idxoid, fillfactor, indkey, generate_series(1,indnatts) AS i
                  FROM (
                      SELECT ci.relname AS idxname, ci.reltuples, ci.relpages, i.indrelid AS tbloid,
                          i.indexrelid AS idxoid,
                          coalesce(substring(
                              array_to_string(ci.reloptions, ' ')
                              from 'fillfactor=([0-9]+)')::smallint, 90) AS fillfactor,
                          i.indnatts,
                          string_to_array(textin(int2vectorout(i.indkey)),' ')::int[] AS indkey
                      FROM pg_index i
                      JOIN pg_class ci ON ci.oid=i.indexrelid
                      WHERE ci.relam=(SELECT oid FROM pg_am WHERE amname = 'btree')
                        AND ci.relpages > 0
                  ) AS idx_data
              ) AS idx_data_cross
          ) i
          JOIN pg_attribute a ON a.attrelid = i.att_rel
                             AND a.attnum = i.att_pos
          JOIN pg_statistic s ON s.starelid = i.att_rel
                             AND s.staattnum = i.att_pos
          JOIN pg_class ct ON ct.oid = i.tbloid
          JOIN pg_namespace n ON ct.relnamespace = n.oid
          GROUP BY 1,2,3,4,5,6,7,8,9,10
      ) AS rows_data_stats
  ) AS rows_hdr_pdg_stats
) AS relation_stats;
$$;


ALTER FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) OWNER TO postgres;

--
-- Name: get_table_bloat_approx(); Type: FUNCTION; Schema: metric_helpers; Owner: postgres
--

CREATE FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) RETURNS SETOF record
    LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
SELECT
  current_database(),
  schemaname,
  tblname,
  (bs*tblpages) AS real_size,
  ((tblpages-est_tblpages)*bs) AS extra_size,
  CASE WHEN tblpages - est_tblpages > 0
    THEN 100 * (tblpages - est_tblpages)/tblpages::float
    ELSE 0
  END AS extra_ratio,
  fillfactor,
  CASE WHEN tblpages - est_tblpages_ff > 0
    THEN (tblpages-est_tblpages_ff)*bs
    ELSE 0
  END AS bloat_size,
  CASE WHEN tblpages - est_tblpages_ff > 0
    THEN 100 * (tblpages - est_tblpages_ff)/tblpages::float
    ELSE 0
  END AS bloat_ratio,
  is_na
FROM (
  SELECT ceil( reltuples / ( (bs-page_hdr)/tpl_size ) ) + ceil( toasttuples / 4 ) AS est_tblpages,
    ceil( reltuples / ( (bs-page_hdr)*fillfactor/(tpl_size*100) ) ) + ceil( toasttuples / 4 ) AS est_tblpages_ff,
    tblpages, fillfactor, bs, tblid, schemaname, tblname, heappages, toastpages, is_na
    -- , tpl_hdr_size, tpl_data_size, pgstattuple(tblid) AS pst -- (DEBUG INFO)
  FROM (
    SELECT
      ( 4 + tpl_hdr_size + tpl_data_size + (2*ma)
        - CASE WHEN tpl_hdr_size%ma = 0 THEN ma ELSE tpl_hdr_size%ma END
        - CASE WHEN ceil(tpl_data_size)::int%ma = 0 THEN ma ELSE ceil(tpl_data_size)::int%ma END
      ) AS tpl_size, bs - page_hdr AS size_per_block, (heappages + toastpages) AS tblpages, heappages,
      toastpages, reltuples, toasttuples, bs, page_hdr, tblid, schemaname, tblname, fillfactor, is_na
      -- , tpl_hdr_size, tpl_data_size
    FROM (
      SELECT
        tbl.oid AS tblid, ns.nspname AS schemaname, tbl.relname AS tblname, tbl.reltuples,
        tbl.relpages AS heappages, coalesce(toast.relpages, 0) AS toastpages,
        coalesce(toast.reltuples, 0) AS toasttuples,
        coalesce(substring(
          array_to_string(tbl.reloptions, ' ')
          FROM 'fillfactor=([0-9]+)')::smallint, 100) AS fillfactor,
        current_setting('block_size')::numeric AS bs,
        CASE WHEN version()~'mingw32' OR version()~'64-bit|x86_64|ppc64|ia64|amd64' THEN 8 ELSE 4 END AS ma,
        24 AS page_hdr,
        23 + CASE WHEN MAX(coalesce(s.null_frac,0)) > 0 THEN ( 7 + count(s.attname) ) / 8 ELSE 0::int END
           + CASE WHEN bool_or(att.attname = 'oid' and att.attnum < 0) THEN 4 ELSE 0 END AS tpl_hdr_size,
        sum( (1-coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 0) ) AS tpl_data_size,
        bool_or(att.atttypid = 'pg_catalog.name'::regtype)
          OR sum(CASE WHEN att.attnum > 0 THEN 1 ELSE 0 END) <> count(s.attname) AS is_na
      FROM pg_attribute AS att
        JOIN pg_class AS tbl ON att.attrelid = tbl.oid
        JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
        LEFT JOIN pg_stats AS s ON s.schemaname=ns.nspname
          AND s.tablename = tbl.relname AND s.inherited=false AND s.attname=att.attname
        LEFT JOIN pg_class AS toast ON tbl.reltoastrelid = toast.oid
      WHERE NOT att.attisdropped
        AND tbl.relkind = 'r'
      GROUP BY 1,2,3,4,5,6,7,8,9,10
      ORDER BY 2,3
    ) AS s
  ) AS s2
) AS s3 WHERE schemaname NOT LIKE 'information_schema';
$$;


ALTER FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) OWNER TO postgres;

--
-- Name: pg_stat_statements(boolean); Type: FUNCTION; Schema: metric_helpers; Owner: postgres
--

CREATE FUNCTION metric_helpers.pg_stat_statements(showtext boolean) RETURNS SETOF public.pg_stat_statements
    LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER
    AS $$
  SELECT * FROM public.pg_stat_statements(showtext);
$$;


ALTER FUNCTION metric_helpers.pg_stat_statements(showtext boolean) OWNER TO postgres;

--
-- Name: comp_ethernet_interfaces_update(); Type: FUNCTION; Schema: public; Owner: hmsdsuser
--

CREATE FUNCTION public.comp_ethernet_interfaces_update() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    comp_ethernet_interface RECORD;
BEGIN
    FOR comp_ethernet_interface IN SELECT id, json_build_array(json_build_object('IPAddress', ipaddr, 'Network', '')) as ip_addresses
                                   FROM comp_eth_interfaces
                                   WHERE ipaddr != ''
        LOOP
            UPDATE comp_eth_interfaces
            SET ip_addresses = comp_ethernet_interface.ip_addresses
            WHERE id = comp_ethernet_interface.id;
        END LOOP;
END;
$$;


ALTER FUNCTION public.comp_ethernet_interfaces_update() OWNER TO hmsdsuser;

--
-- Name: comp_lock_update_reservations(); Type: FUNCTION; Schema: public; Owner: hmsdsuser
--

CREATE FUNCTION public.comp_lock_update_reservations() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    lock_member RECORD;
BEGIN
    FOR lock_member IN SELECT
        component_lock_members.component_id AS "comp_id",
        component_lock_members.lock_id AS "lock_id",
        component_locks.created AS "created",
        component_locks.lifetime AS "lifetime"
    FROM component_lock_members LEFT JOIN component_locks ON component_lock_members.lock_id = component_locks.id LOOP
        INSERT INTO reservations (
            component_id, create_timestamp, expiration_timestamp, deputy_key, reservation_key, v1_lock_id)
        VALUES (
            lock_member.comp_id,
            lock_member.created,
            lock_member.created + (lock_member.lifetime || ' seconds')::interval,
            lock_member.comp_id || ':dk:' || lock_member.lock_id::text,
            lock_member.comp_id || ':rk:' || lock_member.lock_id::text,
            lock_member.lock_id);
    END LOOP;
END;
$$;


ALTER FUNCTION public.comp_lock_update_reservations() OWNER TO hmsdsuser;

--
-- Name: hwinv_by_loc_update_parents(); Type: FUNCTION; Schema: public; Owner: hmsdsuser
--

CREATE FUNCTION public.hwinv_by_loc_update_parents() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    node_id RECORD;
BEGIN
    FOR node_id IN SELECT id FROM hwinv_by_loc WHERE type = 'Node' LOOP
        UPDATE hwinv_by_loc SET parent_node = node_id.id WHERE id SIMILAR TO node_id.id||'([[:alpha:]][[:alnum:]]*)?';
    END LOOP;
    UPDATE hwinv_by_loc SET parent_node = id WHERE parent_node = '';
END;
$$;


ALTER FUNCTION public.hwinv_by_loc_update_parents() OWNER TO hmsdsuser;

--
-- Name: hwinv_hist_prune(); Type: FUNCTION; Schema: public; Owner: hmsdsuser
--

CREATE FUNCTION public.hwinv_hist_prune() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    comp_id RECORD;
    fru_event1 RECORD;
    fru_event2 RECORD;
BEGIN
    FOR comp_id IN SELECT distinct id FROM hwinv_hist LOOP
        SELECT * INTO fru_event1 FROM hwinv_hist WHERE id = comp_id.id ORDER BY timestamp ASC LIMIT 1;
        FOR fru_event2 IN SELECT * FROM hwinv_hist WHERE id = comp_id.id AND timestamp != fru_event1.timestamp ORDER BY timestamp ASC LOOP
            IF fru_event2.fru_id = fru_event1.fru_id THEN
                DELETE FROM hwinv_hist WHERE id = fru_event2.id AND fru_id = fru_event2.fru_id AND timestamp = fru_event2.timestamp;
            ELSE
                fru_event1 = fru_event2;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;


ALTER FUNCTION public.hwinv_hist_prune() OWNER TO hmsdsuser;

--
-- Name: create_application_user(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.create_application_user(username text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $_$
DECLARE
    pw text;
BEGIN
    SELECT user_management.random_password(20) INTO pw;
    EXECUTE format($$ CREATE USER %I WITH PASSWORD %L $$, username, pw);
    RETURN pw;
END
$_$;


ALTER FUNCTION user_management.create_application_user(username text) OWNER TO postgres;

--
-- Name: FUNCTION create_application_user(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.create_application_user(username text) IS 'Creates a user that can login, sets the password to a strong random one,
which is then returned';


--
-- Name: create_application_user_or_change_password(text, text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.create_application_user_or_change_password(username text, password text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $_$
BEGIN
    PERFORM 1 FROM pg_roles WHERE rolname = username;

    IF FOUND
    THEN
        EXECUTE format($$ ALTER ROLE %I WITH PASSWORD %L $$, username, password);
    ELSE
        EXECUTE format($$ CREATE USER %I WITH PASSWORD %L $$, username, password);
    END IF;
END
$_$;


ALTER FUNCTION user_management.create_application_user_or_change_password(username text, password text) OWNER TO postgres;

--
-- Name: FUNCTION create_application_user_or_change_password(username text, password text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.create_application_user_or_change_password(username text, password text) IS 'USE THIS ONLY IN EMERGENCY!  The password will appear in the DB logs.
Creates a user that can login, sets the password to the one provided.
If the user already exists, sets its password.';


--
-- Name: create_role(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.create_role(rolename text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $_$
BEGIN
    -- set ADMIN to the admin user, so every member of admin can GRANT these roles to each other
    EXECUTE format($$ CREATE ROLE %I WITH ADMIN admin $$, rolename);
END;
$_$;


ALTER FUNCTION user_management.create_role(rolename text) OWNER TO postgres;

--
-- Name: FUNCTION create_role(rolename text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.create_role(rolename text) IS 'Creates a role that cannot log in, but can be used to set up fine-grained privileges';


--
-- Name: create_user(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.create_user(username text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $_$
BEGIN
    EXECUTE format($$ CREATE USER %I IN ROLE zalandos, admin $$, username);
    EXECUTE format($$ ALTER ROLE %I SET log_statement TO 'all' $$, username);
END;
$_$;


ALTER FUNCTION user_management.create_user(username text) OWNER TO postgres;

--
-- Name: FUNCTION create_user(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.create_user(username text) IS 'Creates a user that is supposed to be a human, to be authenticated without a password';


--
-- Name: drop_role(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.drop_role(username text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
SELECT user_management.drop_user(username);
$$;


ALTER FUNCTION user_management.drop_role(username text) OWNER TO postgres;

--
-- Name: FUNCTION drop_role(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.drop_role(username text) IS 'Drop a human or application user.  Intended for cleanup (either after team changes or mistakes in role setup).
Roles (= users) that own database objects cannot be dropped.';


--
-- Name: drop_user(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.drop_user(username text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $_$
BEGIN
    EXECUTE format($$ DROP ROLE %I $$, username);
END
$_$;


ALTER FUNCTION user_management.drop_user(username text) OWNER TO postgres;

--
-- Name: FUNCTION drop_user(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.drop_user(username text) IS 'Drop a human or application user.  Intended for cleanup (either after team changes or mistakes in role setup).
Roles (= users) that own database objects cannot be dropped.';


--
-- Name: random_password(integer); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.random_password(length integer) RETURNS text
    LANGUAGE sql
    SET search_path TO 'pg_catalog'
    AS $$
WITH chars (c) AS (
    SELECT chr(33)
    UNION ALL
    SELECT chr(i) FROM generate_series (35, 38) AS t (i)
    UNION ALL
    SELECT chr(i) FROM generate_series (42, 90) AS t (i)
    UNION ALL
    SELECT chr(i) FROM generate_series (97, 122) AS t (i)
),
bricks (b) AS (
    -- build a pool of chars (the size will be the number of chars above times length)
    -- and shuffle it
    SELECT c FROM chars, generate_series(1, length) ORDER BY random()
)
SELECT substr(string_agg(b, ''), 1, length) FROM bricks;
$$;


ALTER FUNCTION user_management.random_password(length integer) OWNER TO postgres;

--
-- Name: revoke_admin(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.revoke_admin(username text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $_$
BEGIN
    EXECUTE format($$ REVOKE admin FROM %I $$, username);
END
$_$;


ALTER FUNCTION user_management.revoke_admin(username text) OWNER TO postgres;

--
-- Name: FUNCTION revoke_admin(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.revoke_admin(username text) IS 'Use this function to make a human user less privileged,
ie. when you want to grant someone read privileges only';


--
-- Name: terminate_backend(integer); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.terminate_backend(pid integer) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
SELECT pg_terminate_backend(pid);
$$;


ALTER FUNCTION user_management.terminate_backend(pid integer) OWNER TO postgres;

--
-- Name: FUNCTION terminate_backend(pid integer); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.terminate_backend(pid integer) IS 'When there is a process causing harm, you can kill it using this function.  Get the pid from pg_stat_activity
(be careful to match the user name (usename) and the query, in order not to kill innocent kittens) and pass it to terminate_backend()';


--
-- Name: index_bloat; Type: VIEW; Schema: metric_helpers; Owner: postgres
--

CREATE VIEW metric_helpers.index_bloat AS
 SELECT get_btree_bloat_approx.i_database,
    get_btree_bloat_approx.i_schema_name,
    get_btree_bloat_approx.i_table_name,
    get_btree_bloat_approx.i_index_name,
    get_btree_bloat_approx.i_real_size,
    get_btree_bloat_approx.i_extra_size,
    get_btree_bloat_approx.i_extra_ratio,
    get_btree_bloat_approx.i_fill_factor,
    get_btree_bloat_approx.i_bloat_size,
    get_btree_bloat_approx.i_bloat_ratio,
    get_btree_bloat_approx.i_is_na
   FROM metric_helpers.get_btree_bloat_approx() get_btree_bloat_approx(i_database, i_schema_name, i_table_name, i_index_name, i_real_size, i_extra_size, i_extra_ratio, i_fill_factor, i_bloat_size, i_bloat_ratio, i_is_na);


ALTER TABLE metric_helpers.index_bloat OWNER TO postgres;

--
-- Name: pg_stat_statements; Type: VIEW; Schema: metric_helpers; Owner: postgres
--

CREATE VIEW metric_helpers.pg_stat_statements AS
 SELECT pg_stat_statements.userid,
    pg_stat_statements.dbid,
    pg_stat_statements.queryid,
    pg_stat_statements.query,
    pg_stat_statements.calls,
    pg_stat_statements.total_time,
    pg_stat_statements.min_time,
    pg_stat_statements.max_time,
    pg_stat_statements.mean_time,
    pg_stat_statements.stddev_time,
    pg_stat_statements.rows,
    pg_stat_statements.shared_blks_hit,
    pg_stat_statements.shared_blks_read,
    pg_stat_statements.shared_blks_dirtied,
    pg_stat_statements.shared_blks_written,
    pg_stat_statements.local_blks_hit,
    pg_stat_statements.local_blks_read,
    pg_stat_statements.local_blks_dirtied,
    pg_stat_statements.local_blks_written,
    pg_stat_statements.temp_blks_read,
    pg_stat_statements.temp_blks_written,
    pg_stat_statements.blk_read_time,
    pg_stat_statements.blk_write_time
   FROM metric_helpers.pg_stat_statements(true) pg_stat_statements(userid, dbid, queryid, query, calls, total_time, min_time, max_time, mean_time, stddev_time, rows, shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written, local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written, temp_blks_read, temp_blks_written, blk_read_time, blk_write_time);


ALTER TABLE metric_helpers.pg_stat_statements OWNER TO postgres;

--
-- Name: table_bloat; Type: VIEW; Schema: metric_helpers; Owner: postgres
--

CREATE VIEW metric_helpers.table_bloat AS
 SELECT get_table_bloat_approx.t_database,
    get_table_bloat_approx.t_schema_name,
    get_table_bloat_approx.t_table_name,
    get_table_bloat_approx.t_real_size,
    get_table_bloat_approx.t_extra_size,
    get_table_bloat_approx.t_extra_ratio,
    get_table_bloat_approx.t_fill_factor,
    get_table_bloat_approx.t_bloat_size,
    get_table_bloat_approx.t_bloat_ratio,
    get_table_bloat_approx.t_is_na
   FROM metric_helpers.get_table_bloat_approx() get_table_bloat_approx(t_database, t_schema_name, t_table_name, t_real_size, t_extra_size, t_extra_ratio, t_fill_factor, t_bloat_size, t_bloat_ratio, t_is_na);


ALTER TABLE metric_helpers.table_bloat OWNER TO postgres;

SET default_tablespace = '';

--
-- Name: comp_endpoints; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.comp_endpoints (
    id character varying(63) NOT NULL,
    type character varying(63) NOT NULL,
    domain character varying(192) NOT NULL,
    redfish_type character varying(63) NOT NULL,
    redfish_subtype character varying(63) NOT NULL,
    rf_endpoint_id character varying(63) NOT NULL,
    mac character varying(32),
    uuid character varying(64),
    odata_id character varying(512) NOT NULL,
    component_info json
);


ALTER TABLE public.comp_endpoints OWNER TO hmsdsuser;

--
-- Name: rf_endpoints; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.rf_endpoints (
    id character varying(63) NOT NULL,
    type character varying(63) NOT NULL,
    name text,
    hostname character varying(63),
    domain character varying(192),
    fqdn character varying(255),
    ip_info json DEFAULT '{}'::json,
    enabled boolean,
    uuid character varying(64),
    "user" character varying(128),
    password character varying(128),
    usessdp boolean,
    macrequired boolean,
    macaddr character varying(32),
    rediscoveronupdate boolean,
    templateid character varying(128),
    discovery_info json,
    ipaddr character varying(64) DEFAULT ''::character varying NOT NULL
);


ALTER TABLE public.rf_endpoints OWNER TO hmsdsuser;

--
-- Name: comp_endpoints_info; Type: VIEW; Schema: public; Owner: hmsdsuser
--

CREATE VIEW public.comp_endpoints_info AS
 SELECT comp_endpoints.id,
    comp_endpoints.type,
    comp_endpoints.domain,
    comp_endpoints.redfish_type,
    comp_endpoints.redfish_subtype,
    comp_endpoints.mac,
    comp_endpoints.uuid,
    comp_endpoints.odata_id,
    comp_endpoints.rf_endpoint_id,
    rf_endpoints.fqdn AS rf_endpoint_fqdn,
    comp_endpoints.component_info,
    rf_endpoints."user" AS rf_endpoint_user,
    rf_endpoints.password AS rf_endpoint_password,
    rf_endpoints.enabled
   FROM (public.comp_endpoints
     LEFT JOIN public.rf_endpoints ON (((comp_endpoints.rf_endpoint_id)::text = (rf_endpoints.id)::text)));


ALTER TABLE public.comp_endpoints_info OWNER TO hmsdsuser;

--
-- Name: comp_eth_interfaces; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.comp_eth_interfaces (
    id character varying(32) NOT NULL,
    description text,
    macaddr character varying(32) NOT NULL,
    last_update timestamp with time zone,
    compid character varying(63) DEFAULT ''::character varying NOT NULL,
    comptype character varying(63) DEFAULT ''::character varying NOT NULL,
    ip_addresses json DEFAULT '[]'::json NOT NULL
);


ALTER TABLE public.comp_eth_interfaces OWNER TO hmsdsuser;

--
-- Name: component_group_members; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.component_group_members (
    component_id character varying(63) NOT NULL,
    group_id uuid NOT NULL,
    group_namespace character varying(255) NOT NULL,
    joined_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.component_group_members OWNER TO hmsdsuser;

--
-- Name: component_groups; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.component_groups (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description character varying(255) NOT NULL,
    tags character varying(255)[],
    annotations json DEFAULT '{}'::json,
    type public.group_type,
    namespace public.group_namespace,
    exclusive_group_identifier character varying(253)
);


ALTER TABLE public.component_groups OWNER TO hmsdsuser;

--
-- Name: components; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.components (
    id character varying(63) NOT NULL,
    type character varying(63) NOT NULL,
    state character varying(32) NOT NULL,
    admin character varying(32) DEFAULT ''::character varying NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    flag character varying(32) NOT NULL,
    role character varying(32) NOT NULL,
    nid bigint NOT NULL,
    subtype character varying(64) NOT NULL,
    nettype character varying(64) NOT NULL,
    arch character varying(64) NOT NULL,
    disposition character varying(64) DEFAULT ''::character varying NOT NULL,
    subrole character varying(32) DEFAULT ''::character varying NOT NULL,
    class character varying(32) DEFAULT ''::character varying NOT NULL,
    reservation_disabled boolean DEFAULT false NOT NULL,
    locked boolean DEFAULT false NOT NULL
);


ALTER TABLE public.components OWNER TO hmsdsuser;

--
-- Name: discovery_status; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.discovery_status (
    id integer NOT NULL,
    status character varying(128),
    last_update timestamp with time zone,
    details json
);


ALTER TABLE public.discovery_status OWNER TO hmsdsuser;

--
-- Name: hsn_interfaces; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.hsn_interfaces (
    nic character varying(32) NOT NULL,
    macaddr character varying(32) DEFAULT ''::character varying NOT NULL,
    hsn character varying(32) DEFAULT ''::character varying NOT NULL,
    node character varying(32) DEFAULT ''::character varying NOT NULL,
    ipaddr character varying(64) DEFAULT ''::character varying NOT NULL,
    last_update timestamp with time zone
);


ALTER TABLE public.hsn_interfaces OWNER TO hmsdsuser;

--
-- Name: hwinv_by_fru; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.hwinv_by_fru (
    fru_id character varying(255) NOT NULL,
    type character varying(63) NOT NULL,
    subtype character varying(63) NOT NULL,
    serial_number character varying(255) DEFAULT ''::character varying NOT NULL,
    part_number character varying(255) DEFAULT ''::character varying NOT NULL,
    manufacturer character varying(255) DEFAULT ''::character varying NOT NULL,
    fru_info json NOT NULL
);


ALTER TABLE public.hwinv_by_fru OWNER TO hmsdsuser;

--
-- Name: hwinv_by_loc; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.hwinv_by_loc (
    id character varying(63) NOT NULL,
    type character varying(63) NOT NULL,
    ordinal integer NOT NULL,
    status character varying(63) NOT NULL,
    parent character varying(63) DEFAULT ''::character varying NOT NULL,
    location_info json,
    fru_id character varying(255),
    parent_node character varying(63) DEFAULT ''::character varying NOT NULL
);


ALTER TABLE public.hwinv_by_loc OWNER TO hmsdsuser;

--
-- Name: hwinv_by_loc_with_fru; Type: VIEW; Schema: public; Owner: hmsdsuser
--

CREATE VIEW public.hwinv_by_loc_with_fru AS
 SELECT hwinv_by_loc.id,
    hwinv_by_loc.type,
    hwinv_by_loc.ordinal,
    hwinv_by_loc.status,
    hwinv_by_loc.location_info,
    hwinv_by_loc.fru_id,
    hwinv_by_fru.type AS fru_type,
    hwinv_by_fru.subtype AS fru_subtype,
    hwinv_by_fru.fru_info
   FROM (public.hwinv_by_loc
     LEFT JOIN public.hwinv_by_fru ON (((hwinv_by_loc.fru_id)::text = (hwinv_by_fru.fru_id)::text)));


ALTER TABLE public.hwinv_by_loc_with_fru OWNER TO hmsdsuser;

--
-- Name: hwinv_by_loc_with_partition; Type: VIEW; Schema: public; Owner: hmsdsuser
--

CREATE VIEW public.hwinv_by_loc_with_partition AS
 SELECT hwinv_by_loc.id,
    hwinv_by_loc.type,
    hwinv_by_loc.ordinal,
    hwinv_by_loc.status,
    hwinv_by_loc.location_info,
    hwinv_by_loc.fru_id,
    hwinv_by_fru.type AS fru_type,
    hwinv_by_fru.subtype AS fru_subtype,
    hwinv_by_fru.fru_info,
    part_info.name AS partition
   FROM ((public.hwinv_by_loc
     LEFT JOIN public.hwinv_by_fru ON (((hwinv_by_loc.fru_id)::text = (hwinv_by_fru.fru_id)::text)))
     LEFT JOIN ( SELECT component_group_members.component_id AS id,
            component_groups.name
           FROM (public.component_group_members
             LEFT JOIN public.component_groups ON ((component_group_members.group_id = component_groups.id)))
          WHERE ((component_group_members.group_namespace)::text = '%%partition%%'::text)) part_info ON (((hwinv_by_loc.parent_node)::text = (part_info.id)::text)));


ALTER TABLE public.hwinv_by_loc_with_partition OWNER TO hmsdsuser;

--
-- Name: hwinv_hist; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.hwinv_hist (
    id character varying(63),
    fru_id character varying(255),
    event_type character varying(128),
    "timestamp" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.hwinv_hist OWNER TO hmsdsuser;

--
-- Name: job_state_rf_poll; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.job_state_rf_poll (
    comp_id character varying(63) NOT NULL,
    job_id uuid NOT NULL
);


ALTER TABLE public.job_state_rf_poll OWNER TO hmsdsuser;

--
-- Name: job_sync; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.job_sync (
    id uuid NOT NULL,
    type character varying(128),
    status character varying(128),
    last_update timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    lifetime integer NOT NULL
);


ALTER TABLE public.job_sync OWNER TO hmsdsuser;

--
-- Name: node_nid_mapping; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.node_nid_mapping (
    id character varying(63) NOT NULL,
    nid bigint,
    role character varying(32) NOT NULL,
    name character varying(32) DEFAULT ''::character varying NOT NULL,
    node_info json,
    subrole character varying(32) DEFAULT ''::character varying NOT NULL
);


ALTER TABLE public.node_nid_mapping OWNER TO hmsdsuser;

--
-- Name: power_mapping; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.power_mapping (
    id character varying(63) NOT NULL,
    powered_by character varying(63)[] NOT NULL
);


ALTER TABLE public.power_mapping OWNER TO hmsdsuser;

--
-- Name: reservations; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.reservations (
    component_id character varying(63) NOT NULL,
    create_timestamp timestamp with time zone NOT NULL,
    expiration_timestamp timestamp with time zone,
    deputy_key character varying,
    reservation_key character varying
);


ALTER TABLE public.reservations OWNER TO hmsdsuser;

--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    dirty boolean NOT NULL
);


ALTER TABLE public.schema_migrations OWNER TO hmsdsuser;

--
-- Name: scn_subscriptions; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.scn_subscriptions (
    id integer NOT NULL,
    sub_url character varying(255) NOT NULL,
    subscription json DEFAULT '{}'::json
);


ALTER TABLE public.scn_subscriptions OWNER TO hmsdsuser;

--
-- Name: scn_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: hmsdsuser
--

CREATE SEQUENCE public.scn_subscriptions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.scn_subscriptions_id_seq OWNER TO hmsdsuser;

--
-- Name: scn_subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: hmsdsuser
--

ALTER SEQUENCE public.scn_subscriptions_id_seq OWNED BY public.scn_subscriptions.id;


--
-- Name: service_endpoints; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.service_endpoints (
    rf_endpoint_id character varying(63) NOT NULL,
    redfish_type character varying(63) NOT NULL,
    redfish_subtype character varying(63) NOT NULL,
    uuid character varying(64),
    odata_id character varying(512) NOT NULL,
    service_info json
);


ALTER TABLE public.service_endpoints OWNER TO hmsdsuser;

--
-- Name: service_endpoints_info; Type: VIEW; Schema: public; Owner: hmsdsuser
--

CREATE VIEW public.service_endpoints_info AS
 SELECT service_endpoints.rf_endpoint_id,
    service_endpoints.redfish_type,
    service_endpoints.redfish_subtype,
    service_endpoints.uuid,
    service_endpoints.odata_id,
    rf_endpoints.fqdn AS rf_endpoint_fqdn,
    service_endpoints.service_info
   FROM (public.service_endpoints
     LEFT JOIN public.rf_endpoints ON (((service_endpoints.rf_endpoint_id)::text = (rf_endpoints.id)::text)));


ALTER TABLE public.service_endpoints_info OWNER TO hmsdsuser;

--
-- Name: system; Type: TABLE; Schema: public; Owner: hmsdsuser
--

CREATE TABLE public.system (
    id integer NOT NULL,
    schema_version integer NOT NULL,
    system_info json
);


ALTER TABLE public.system OWNER TO hmsdsuser;

--
-- Name: scn_subscriptions id; Type: DEFAULT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.scn_subscriptions ALTER COLUMN id SET DEFAULT nextval('public.scn_subscriptions_id_seq'::regclass);


--
-- Data for Name: comp_endpoints; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.comp_endpoints (id, type, domain, redfish_type, redfish_subtype, rf_endpoint_id, mac, uuid, odata_id, component_info) FROM stdin;
x3000c0s8e0	NodeEnclosure		Chassis	RackMount	x3000c0s8b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s8b0n0	Node		ComputerSystem	Physical	x3000c0s8b0		36383150-3630-584D-5130-333030305439	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"94:40:c9:5f:b6:5c"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","InterfaceEnabled":false,"MACAddress":"94:40:c9:5f:b6:5d"},{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","InterfaceEnabled":true,"MACAddress":"14:02:ec:d9:7b:c8"},{"RedfishId":"4","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/4","InterfaceEnabled":false,"MACAddress":"14:02:ec:d9:7b:c9"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s2e0	NodeEnclosure		Chassis	RackMount	x3000c0s2b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s9e0	NodeEnclosure		Chassis	RackMount	x3000c0s9b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s7b0n0	Node		ComputerSystem	Physical	x3000c0s7b0		36383150-3630-584D-5130-333030305442	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","InterfaceEnabled":true,"MACAddress":"14:02:ec:d9:7c:88"},{"RedfishId":"4","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/4","InterfaceEnabled":false,"MACAddress":"14:02:ec:d9:7c:89"},{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"94:40:c9:5f:9a:a8"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","InterfaceEnabled":false,"MACAddress":"94:40:c9:5f:9a:a9"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s7b0	NodeBMC		Manager	BMC	x3000c0s7b0	0a:ca:fe:f0:0d:04	47b08c81-e20f-598c-bb4f-66df356d14e5	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000TB.hmn","Hostname":"ILOMXQ03000TB","InterfaceEnabled":true,"MACAddress":"94:40:c9:37:0a:2a","PermanentMACAddress":"94:40:c9:37:0a:2a"},{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ03000TB","InterfaceEnabled":false,"MACAddress":"94:40:c9:37:0a:2b","PermanentMACAddress":"94:40:c9:37:0a:2b"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"}]}
x3000c0s6e0	NodeEnclosure		Chassis	RackMount	x3000c0s6b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s6b0n0	Node		ComputerSystem	Physical	x3000c0s6b0		36383150-3630-584D-5130-33303030544A	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"ec:0d:9a:d9:c5:26"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","MACAddress":"14:02:ec:da:bb:00"},{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","MACAddress":"14:02:ec:da:bb:01"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0r15e0	HSNBoard		Chassis	Enclosure	x3000c0r15b0			/redfish/v1/Chassis/Enclosure	{"Name":"Enclosure","Actions":{"#Chassis.Reset":{"ResetType@Redfish.AllowableValues":["GracefulShutdown","ForceOff","Off","GracefulRestart","ForceRestart","ForceOn","PowerCycle","On"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Chassis/Enclosure/Actions/Chassis.Reset"}}}
x3000c0s17e2	NodeEnclosure		Chassis	RackMount	x3000c0s17b2			/redfish/v1/Chassis/Self	{"Name":"Computer System Chassis","Actions":{"#Chassis.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Chassis/Self/ResetActionInfo","target":"/redfish/v1/Chassis/Self/Actions/Chassis.Reset"}}}
x3000c0s5e0	NodeEnclosure		Chassis	RackMount	x3000c0s5b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s4e0	NodeEnclosure		Chassis	RackMount	x3000c0s4b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s4b0n0	Node		ComputerSystem	Physical	x3000c0s4b0		36383150-3630-584D-5130-33303030544B	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","InterfaceEnabled":true,"MACAddress":"98:03:9b:3f:b8:82"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","InterfaceEnabled":true,"MACAddress":"14:02:ec:d9:7c:40"},{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","MACAddress":"14:02:ec:d9:7c:41"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s4b0	NodeBMC		Manager	BMC	x3000c0s4b0	0a:ca:fe:f0:0d:04	0a1b9696-30a1-5f58-be22-658c27e6fb6f	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000TK.hmn","Hostname":"ILOMXQ03000TK","InterfaceEnabled":true,"MACAddress":"94:40:c9:37:67:60","PermanentMACAddress":"94:40:c9:37:67:60"},{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ03000TK","InterfaceEnabled":false,"MACAddress":"94:40:c9:37:67:61","PermanentMACAddress":"94:40:c9:37:67:61"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"}]}
x3000c0r15b0	RouterBMC		Manager	EnclosureManager	x3000c0r15b0			/redfish/v1/Managers/BMC	{"Name":"BMC","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","StatefulReset"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/BMC/Actions/Manager.Reset"},"Oem":{"#CrayProcess.Schedule":{"Name@Redfish.AllowableValues":["memtest","cpuburn"],"target":"/redfish/v1/Managers/BMC/Actions/Oem/CrayProcess.Schedule"}}}}
x3000c0s17e3	NodeEnclosure		Chassis	RackMount	x3000c0s17b3			/redfish/v1/Chassis/Self	{"Name":"Computer System Chassis","Actions":{"#Chassis.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Chassis/Self/ResetActionInfo","target":"/redfish/v1/Chassis/Self/Actions/Chassis.Reset"}}}
x3000c0s17b3n0	Node		ComputerSystem	Physical	x3000c0s17b3		70518000-5ab2-11eb-8000-b42e99dfebbf	/redfish/v1/Systems/Self	{"Name":"System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["GracefulShutdown","ForceOff","On","ForceRestart"],"@Redfish.ActionInfo":"/redfish/v1/Systems/Self/ResetActionInfo","target":"/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/Self/EthernetInterfaces/1","Description":"Ethernet Interface Lan1","MACAddress":"b4:2e:99:df:eb:bf"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/Self/EthernetInterfaces/2","Description":"Ethernet Interface Lan2","MACAddress":"b4:2e:99:df:eb:c0"}],"PowerURL":"/redfish/v1/Chassis/Self/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/Self/Power#/PowerControl/0","MemberId":"0","Name":"Chassis Power Control","PowerCapacityWatts":900,"OEM":{},"RelatedItem":[{"@odata.id":"/redfish/v1/Chassis/Self"},{"@odata.id":"/redfish/v1/Systems/Self"}]}]}
x3000c0s17b3	NodeBMC		Manager	BMC	x3000c0s17b3	76:c3:5e:65:6b:11	40f2306f-debf-0010-e903-b42e99dfebc1	/redfish/v1/Managers/Self	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Managers/Self/ResetActionInfo","target":"/redfish/v1/Managers/Self/Actions/Manager.Reset"},"Oem":{}},"EthernetNICInfo":[{"RedfishId":"bond0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/bond0","Description":"Ethernet Interface bond0","FQDN":"AMIB42E99DFEBC1.hmn","Hostname":"AMIB42E99DFEBC1","InterfaceEnabled":true,"MACAddress":"b4:2e:99:df:eb:c1","PermanentMACAddress":"b4:2e:99:df:eb:c1"},{"RedfishId":"usb0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/usb0","Description":"Ethernet Interface usb0","FQDN":"AMIB42E99DFEBC1.hmn","Hostname":"AMIB42E99DFEBC1","InterfaceEnabled":true,"MACAddress":"76:c3:5e:65:6b:11","PermanentMACAddress":"76:c3:5e:65:6b:11"}]}
x3000c0s3e0	NodeEnclosure		Chassis	RackMount	x3000c0s3b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s3b0n0	Node		ComputerSystem	Physical	x3000c0s3b0		36383150-3630-584D-5130-333030305444	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"4","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/4","InterfaceEnabled":false,"MACAddress":"14:02:ec:d9:79:e9"},{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"94:40:c9:5f:b5:cc"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","InterfaceEnabled":false,"MACAddress":"94:40:c9:5f:b5:cd"},{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","InterfaceEnabled":true,"MACAddress":"14:02:ec:d9:79:e8"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s17b2n0	Node		ComputerSystem	Physical	x3000c0s17b2		70518000-5ab2-11eb-8000-b42e99dfecef	/redfish/v1/Systems/Self	{"Name":"System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulShutdown","On","ForceOff"],"@Redfish.ActionInfo":"/redfish/v1/Systems/Self/ResetActionInfo","target":"/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/Self/EthernetInterfaces/1","Description":"Ethernet Interface Lan1","MACAddress":"b4:2e:99:df:ec:ef"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/Self/EthernetInterfaces/2","Description":"Ethernet Interface Lan2","MACAddress":"b4:2e:99:df:ec:f0"}],"PowerURL":"/redfish/v1/Chassis/Self/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/Self/Power#/PowerControl/0","MemberId":"0","Name":"Chassis Power Control","PowerCapacityWatts":900,"OEM":{},"RelatedItem":[{"@odata.id":"/redfish/v1/Chassis/Self"},{"@odata.id":"/redfish/v1/Systems/Self"}]}]}
x3000c0s17b2	NodeBMC		Manager	BMC	x3000c0s17b2	06:03:a2:22:7d:ee	40f2306f-debf-0010-e903-b42e99dfecf1	/redfish/v1/Managers/Self	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Managers/Self/ResetActionInfo","target":"/redfish/v1/Managers/Self/Actions/Manager.Reset"},"Oem":{}},"EthernetNICInfo":[{"RedfishId":"bond0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/bond0","Description":"Ethernet Interface bond0","FQDN":"AMIB42E99DFECF1.hmn","Hostname":"AMIB42E99DFECF1","InterfaceEnabled":true,"MACAddress":"b4:2e:99:df:ec:f1","PermanentMACAddress":"b4:2e:99:df:ec:f1"},{"RedfishId":"usb0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/usb0","Description":"Ethernet Interface usb0","FQDN":"AMIB42E99DFECF1.hmn","Hostname":"AMIB42E99DFECF1","InterfaceEnabled":true,"MACAddress":"06:03:a2:22:7d:ee","PermanentMACAddress":"06:03:a2:22:7d:ee"}]}
x3000c0s17e4	NodeEnclosure		Chassis	RackMount	x3000c0s17b4			/redfish/v1/Chassis/Self	{"Name":"Computer System Chassis","Actions":{"#Chassis.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Chassis/Self/ResetActionInfo","target":"/redfish/v1/Chassis/Self/Actions/Chassis.Reset"}}}
x3000c0s17b4n0	Node		ComputerSystem	Physical	x3000c0s17b4		70518000-5ab2-11eb-8000-b42e99dfec47	/redfish/v1/Systems/Self	{"Name":"System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["GracefulShutdown","On","ForceOff","ForceRestart"],"@Redfish.ActionInfo":"/redfish/v1/Systems/Self/ResetActionInfo","target":"/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/Self/EthernetInterfaces/1","Description":"Ethernet Interface Lan1","MACAddress":"b4:2e:99:df:ec:47"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/Self/EthernetInterfaces/2","Description":"Ethernet Interface Lan2","MACAddress":"b4:2e:99:df:ec:48"}],"PowerURL":"/redfish/v1/Chassis/Self/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/Self/Power#/PowerControl/0","MemberId":"0","Name":"Chassis Power Control","PowerCapacityWatts":900,"OEM":{},"RelatedItem":[{"@odata.id":"/redfish/v1/Systems/Self"},{"@odata.id":"/redfish/v1/Chassis/Self"}]}]}
x3000c0s17b4	NodeBMC		Manager	BMC	x3000c0s17b4	aa:e0:5b:be:df:8e	80694c6f-debf-0010-e903-b42e99dfec49	/redfish/v1/Managers/Self	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Managers/Self/ResetActionInfo","target":"/redfish/v1/Managers/Self/Actions/Manager.Reset"},"Oem":{}},"EthernetNICInfo":[{"RedfishId":"bond0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/bond0","Description":"Ethernet Interface bond0","FQDN":"AMIB42E99DFEC49.hmn","Hostname":"AMIB42E99DFEC49","InterfaceEnabled":true,"MACAddress":"b4:2e:99:df:ec:49","PermanentMACAddress":"b4:2e:99:df:ec:49"},{"RedfishId":"usb0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/usb0","Description":"Ethernet Interface usb0","FQDN":"AMIB42E99DFEC49.hmn","Hostname":"AMIB42E99DFEC49","InterfaceEnabled":true,"MACAddress":"aa:e0:5b:be:df:8e","PermanentMACAddress":"aa:e0:5b:be:df:8e"}]}
x3000c0s17b999	NodeBMC		Manager	BMC	x3000c0s17b999	02:34:e8:54:d1:78	009ea76e-debf-0010-ef03-b42e99bdd255	/redfish/v1/Managers/Self	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Managers/Self/ResetActionInfo","target":"/redfish/v1/Managers/Self/Actions/Manager.Reset"},"Oem":{}},"EthernetNICInfo":[{"RedfishId":"bond0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/bond0","Description":"Ethernet Interface bond0","FQDN":"AMIB42E99BDD255.hmn","Hostname":"AMIB42E99BDD255","InterfaceEnabled":true,"MACAddress":"b4:2e:99:bd:d2:55","PermanentMACAddress":"b4:2e:99:bd:d2:55"},{"RedfishId":"usb0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/usb0","Description":"Ethernet Interface usb0","FQDN":"AMIB42E99BDD255.hmn","Hostname":"AMIB42E99BDD255","InterfaceEnabled":true,"MACAddress":"02:34:e8:54:d1:78","PermanentMACAddress":"02:34:e8:54:d1:78"}]}
x3000c0s17e1	NodeEnclosure		Chassis	RackMount	x3000c0s17b1			/redfish/v1/Chassis/Self	{"Name":"Computer System Chassis","Actions":{"#Chassis.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Chassis/Self/ResetActionInfo","target":"/redfish/v1/Chassis/Self/Actions/Chassis.Reset"}}}
x3000c0s17b1n0	Node		ComputerSystem	Physical	x3000c0s17b1		70518000-5ab2-11eb-8000-b42e99dff35f	/redfish/v1/Systems/Self	{"Name":"System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","ForceRestart","GracefulShutdown"],"@Redfish.ActionInfo":"/redfish/v1/Systems/Self/ResetActionInfo","target":"/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/Self/EthernetInterfaces/1","Description":"Ethernet Interface Lan1","MACAddress":"b4:2e:99:df:f3:5f"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/Self/EthernetInterfaces/2","Description":"Ethernet Interface Lan2","MACAddress":"b4:2e:99:df:f3:60"}],"PowerURL":"/redfish/v1/Chassis/Self/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/Self/Power#/PowerControl/0","MemberId":"0","Name":"Chassis Power Control","PowerCapacityWatts":900,"OEM":{},"RelatedItem":[{"@odata.id":"/redfish/v1/Chassis/Self"},{"@odata.id":"/redfish/v1/Systems/Self"}]}]}
x3000c0s17b1	NodeBMC		Manager	BMC	x3000c0s17b1	46:bb:8c:be:6e:80	40f2306f-debf-0010-e903-b42e99dff361	/redfish/v1/Managers/Self	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":null,"@Redfish.ActionInfo":"/redfish/v1/Managers/Self/ResetActionInfo","target":"/redfish/v1/Managers/Self/Actions/Manager.Reset"},"Oem":{}},"EthernetNICInfo":[{"RedfishId":"bond0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/bond0","Description":"Ethernet Interface bond0","FQDN":"AMIB42E99DFF361.hmn","Hostname":"AMIB42E99DFF361","InterfaceEnabled":true,"MACAddress":"b4:2e:99:df:f3:61","PermanentMACAddress":"b4:2e:99:df:f3:61"},{"RedfishId":"usb0","@odata.id":"/redfish/v1/Managers/Self/EthernetInterfaces/usb0","Description":"Ethernet Interface usb0","FQDN":"AMIB42E99DFF361.hmn","Hostname":"AMIB42E99DFF361","InterfaceEnabled":true,"MACAddress":"46:bb:8c:be:6e:80","PermanentMACAddress":"46:bb:8c:be:6e:80"}]}
x3000c0s19e0	NodeEnclosure		Chassis	RackMount	x3000c0s19b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s19b0n0	Node		ComputerSystem	Physical	x3000c0s19b0		36383150-3630-584D-5130-333030305447	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"94:40:c9:5f:9a:2a"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","MACAddress":"ec:0d:9a:c1:b4:30"},{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","MACAddress":"14:02:ec:da:b8:90"},{"RedfishId":"4","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/4","MACAddress":"14:02:ec:da:b8:91"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s19b0	NodeBMC		Manager	BMC	x3000c0s19b0	94:40:c9:37:67:80	4ff3e345-f8fc-5467-b956-0cd1039c1d5a	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000TG.","Hostname":"ILOMXQ03000TG","InterfaceEnabled":false,"MACAddress":"94:40:c9:37:67:81","PermanentMACAddress":"94:40:c9:37:67:81"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"00:ca:fe:f0:0d:04","PermanentMACAddress":"00:ca:fe:f0:0d:04"},{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000TG.","Hostname":"ILOMXQ03000TG","InterfaceEnabled":true,"MACAddress":"94:40:c9:37:67:80","PermanentMACAddress":"94:40:c9:37:67:80"}]}
x3000c0s7e0	NodeEnclosure		Chassis	RackMount	x3000c0s7b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s9b0n0	Node		ComputerSystem	Physical	x3000c0s9b0		36383150-3630-584D-5130-333030305438	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"94:40:c9:5f:b6:92"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","InterfaceEnabled":false,"MACAddress":"94:40:c9:5f:b6:93"},{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","InterfaceEnabled":true,"MACAddress":"14:02:ec:d9:76:88"},{"RedfishId":"4","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/4","InterfaceEnabled":false,"MACAddress":"14:02:ec:d9:76:89"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s2b0n0	Node		ComputerSystem	Physical	x3000c0s2b0		36383150-3630-584D-5130-333030305443	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"4","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/4","InterfaceEnabled":false,"MACAddress":"14:02:ec:da:b8:19"},{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"94:40:c9:5f:a3:a8"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","InterfaceEnabled":false,"MACAddress":"94:40:c9:5f:a3:a9"},{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","InterfaceEnabled":true,"MACAddress":"14:02:ec:da:b8:18"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s6b0	NodeBMC		Manager	BMC	x3000c0s6b0	0a:ca:fe:f0:0d:04	75a321cb-d377-542e-a977-b9d299d2763c	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000TJ.hmn","Hostname":"ILOMXQ03000TJ","InterfaceEnabled":true,"MACAddress":"94:40:c9:37:77:b8","PermanentMACAddress":"94:40:c9:37:77:b8"},{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ03000TJ","InterfaceEnabled":false,"MACAddress":"94:40:c9:37:77:b9","PermanentMACAddress":"94:40:c9:37:77:b9"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"}]}
x3000c0s3b0	NodeBMC		Manager	BMC	x3000c0s3b0	0a:ca:fe:f0:0d:04	e5966532-7a8e-5f76-b754-69702b6d5689	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000TD.hmn","Hostname":"ILOMXQ03000TD","InterfaceEnabled":true,"MACAddress":"94:40:c9:37:04:84","PermanentMACAddress":"94:40:c9:37:04:84"},{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ03000TD","InterfaceEnabled":false,"MACAddress":"94:40:c9:37:04:85","PermanentMACAddress":"94:40:c9:37:04:85"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"}]}
x3000m1	CabinetPDUController		Manager	EnclosureManager	x3000m1			/redfish/v1/Managers/BMC	{"Name":"BMC","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","StatefulReset"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/BMC/Actions/Manager.Reset"},"Oem":{"#CrayProcess.Schedule":{"Name@Redfish.AllowableValues":["memtest","cpuburn"],"target":"/redfish/v1/Managers/BMC/Actions/Oem/CrayProcess.Schedule"}}}}
x3000c0s5b0n0	Node		ComputerSystem	Physical	x3000c0s5b0		36383150-3630-584D-5130-333030305448	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"98:03:9b:7f:bf:40"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","MACAddress":"98:03:9b:7f:c0:60"},{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","InterfaceEnabled":true,"MACAddress":"14:02:ec:d9:76:b8"},{"RedfishId":"4","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/4","MACAddress":"14:02:ec:d9:76:b9"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1000,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s5b0	NodeBMC		Manager	BMC	x3000c0s5b0	0a:ca:fe:f0:0d:04	adae964c-886c-5fec-8b06-f028e6cde707	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000TH.hmn","Hostname":"ILOMXQ03000TH","InterfaceEnabled":true,"MACAddress":"94:40:c9:35:03:06","PermanentMACAddress":"94:40:c9:35:03:06"},{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ03000TH","InterfaceEnabled":false,"MACAddress":"94:40:c9:35:03:07","PermanentMACAddress":"94:40:c9:35:03:07"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"}]}
x3000c0s9b0	NodeBMC		Manager	BMC	x3000c0s9b0	0a:ca:fe:f0:0d:04	61670f98-145d-514c-a763-84dc5d93f4de	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000T8.hmn","Hostname":"ILOMXQ03000T8","InterfaceEnabled":true,"MACAddress":"94:40:c9:37:77:26","PermanentMACAddress":"94:40:c9:37:77:26"},{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ03000T8","InterfaceEnabled":false,"MACAddress":"94:40:c9:37:77:27","PermanentMACAddress":"94:40:c9:37:77:27"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"}]}
x3000c0s8b0	NodeBMC		Manager	BMC	x3000c0s8b0	0a:ca:fe:f0:0d:04	49aa7311-829d-5813-aabc-42e4e55ee470	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000T9.hmn","Hostname":"ILOMXQ03000T9","InterfaceEnabled":true,"MACAddress":"94:40:c9:37:87:5a","PermanentMACAddress":"94:40:c9:37:87:5a"},{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ03000T9","InterfaceEnabled":false,"MACAddress":"94:40:c9:37:87:5b","PermanentMACAddress":"94:40:c9:37:87:5b"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"}]}
x3000c0s30e0	NodeEnclosure		Chassis	RackMount	x3000c0s30b0			/redfish/v1/Chassis/1	{"Name":"Computer System Chassis"}
x3000c0s30b0n0	Node		ComputerSystem	Physical	x3000c0s30b0		34383350-3137-584D-5131-34383038574D	/redfish/v1/Systems/1	{"Name":"Computer System","Actions":{"#ComputerSystem.Reset":{"ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"}},"EthernetNICInfo":[{"RedfishId":"3","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/3","MACAddress":"14:02:ec:e1:bd:a8"},{"RedfishId":"4","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/4","MACAddress":"14:02:ec:e1:bd:a9"},{"RedfishId":"1","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/1","MACAddress":"88:e9:a4:02:94:14"},{"RedfishId":"2","@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/2","MACAddress":"88:e9:a4:02:84:cc"}],"PowerURL":"/redfish/v1/Chassis/1/Power","PowerControl":[{"@odata.id":"/redfish/v1/Chassis/1/Power#PowerControl/0","MemberId":"0","PowerCapacityWatts":1600,"OEM":{"HPE":{"PowerLimit":{},"PowerRegulationEnabled":false,"Status":"Empty","Target":""}}}]}
x3000c0s2b0	NodeBMC		Manager	BMC	x3000c0s2b0	94:40:c9:37:f9:b4	1df0ed5f-b5f8-5eff-bd6f-ac7fccc008f8	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ03000TC","InterfaceEnabled":false,"MACAddress":"94:40:c9:37:f9:b5","PermanentMACAddress":"94:40:c9:37:f9:b5"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":true,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"},{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ03000TC.hmn","Hostname":"ILOMXQ03000TC","InterfaceEnabled":true,"MACAddress":"94:40:c9:37:f9:b4","PermanentMACAddress":"94:40:c9:37:f9:b4"}]}
x3000c0s30b0	NodeBMC		Manager	BMC	x3000c0s30b0	b4:7a:f1:c2:12:a8	3e5a50d4-75fe-5e31-a95f-c5cca0a04e5e	/redfish/v1/Managers/1	{"Name":"Manager","Actions":{"#Manager.Reset":{"ResetType@Redfish.AllowableValues":["ForceRestart","GracefulRestart"],"@Redfish.ActionInfo":"","target":"/redfish/v1/Managers/1/Actions/Manager.Reset"}},"EthernetNICInfo":[{"RedfishId":"1","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/1","Description":"Configuration of this Manager Network Interface","FQDN":"ILOMXQ14808WM.hmn","Hostname":"ILOMXQ14808WM","InterfaceEnabled":true,"MACAddress":"b4:7a:f1:c2:12:a8","PermanentMACAddress":"b4:7a:f1:c2:12:a8"},{"RedfishId":"2","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/2","Description":"Configuration of this Manager Network Interface","Hostname":"ILOMXQ14808WM","InterfaceEnabled":false,"MACAddress":"b4:7a:f1:c2:12:a9","PermanentMACAddress":"b4:7a:f1:c2:12:a9"},{"RedfishId":"3","@odata.id":"/redfish/v1/Managers/1/EthernetInterfaces/3","Description":"Configuration of this Manager USB Ethernet Interface available for access from Host.","InterfaceEnabled":false,"MACAddress":"0a:ca:fe:f0:0d:04","PermanentMACAddress":"0a:ca:fe:f0:0d:04"}]}
\.


--
-- Data for Name: comp_eth_interfaces; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.comp_eth_interfaces (id, description, macaddr, last_update, compid, comptype, ip_addresses) FROM stdin;
b42e99dfec47	Ethernet Interface Lan1	b4:2e:99:df:ec:47	2022-08-11 21:40:50.962231+00	x3000c0s17b4n0	Node	[{"IPAddress":"10.252.1.15"}]
98039b7fbf40		98:03:9b:7f:bf:40	2022-08-12 21:57:18.340667+00	x3000c0s5b0n0	Node	[{"IPAddress":""}]
ecebb83d88ff		ec:eb:b8:3d:88:ff	2022-08-15 21:42:25.065347+00	x3000m1	CabinetPDUController	[{"IPAddress":"10.254.1.24"}]
b42e99dfebc0	Ethernet Interface Lan2	b4:2e:99:df:eb:c0	2022-08-08 10:10:53.864448+00	x3000c0s17b3n0	Node	[]
b42e99dfecef	Ethernet Interface Lan1	b4:2e:99:df:ec:ef	2022-08-08 11:56:36.426022+00	x3000c0s17b2n0	Node	[{"IPAddress":"10.252.1.14"}]
b47af1c212a9	Configuration of this Manager Network Interface	b4:7a:f1:c2:12:a9	2022-08-18 22:19:34.197953+00	x3000c0s30b0	NodeBMC	[]
1402ecd979e9		14:02:ec:d9:79:e9	2022-08-12 21:57:18.653058+00	x3000c0s3b0n0	Node	[{"IPAddress":""}]
1402ecd976b8	- kea	14:02:ec:d9:76:b8	2022-08-12 22:53:40.982324+00	x3000c0s5b0n0	Node	[{"IPAddress":"10.252.1.8"},{"IPAddress":"10.254.1.12"},{"IPAddress":"10.1.1.6"},{"IPAddress":"10.103.11.23"}]
9440c937f9b5	Configuration of this Manager Network Interface	94:40:c9:37:f9:b5	2022-08-08 09:04:01.19185+00	x3000c0s2b0	NodeBMC	[]
ec0d9ad9c526		ec:0d:9a:d9:c5:26	2022-08-12 21:57:19.055599+00	x3000c0s6b0n0	Node	[{"IPAddress":""}]
9440c95f9a2a		94:40:c9:5f:9a:2a	2022-08-08 10:11:26.824952+00	x3000c0s19b0n0	Node	[]
1402ecdab819		14:02:ec:da:b8:19	2022-08-12 21:57:19.570453+00	x3000c0s2b0n0	Node	[{"IPAddress":""}]
9440c95fa3a8		94:40:c9:5f:a3:a8	2022-08-12 21:57:19.658182+00	x3000c0s2b0n0	Node	[{"IPAddress":""}]
1402ecdab998	- kea	14:02:ec:da:b9:98	2022-08-12 22:53:41.189429+00			[{"IPAddress":"10.252.1.12"},{"IPAddress":"10.254.1.20"},{"IPAddress":"10.1.1.10"},{"IPAddress":"10.103.11.27"}]
9440c95fa3a9		94:40:c9:5f:a3:a9	2022-08-12 21:57:19.586353+00	x3000c0s2b0n0	Node	[{"IPAddress":""}]
9440c95fb5cc		94:40:c9:5f:b5:cc	2022-08-12 21:57:18.734633+00	x3000c0s3b0n0	Node	[{"IPAddress":""}]
b42e99bdd255		b4:2e:99:bd:d2:55	2022-08-08 10:07:01.928963+00	x3000c0s17b999	NodeBMC	[{"IPAddress":"10.254.1.42"}]
9440c95fb65c		94:40:c9:5f:b6:5c	2022-08-12 21:57:20.094131+00	x3000c0s8b0n0	Node	[{"IPAddress":""}]
9440c937f9b4	Configuration of this Manager Network Interface	94:40:c9:37:f9:b4	2022-08-08 09:04:01.19185+00	x3000c0s2b0	NodeBMC	[]
9440c95fb5cd		94:40:c9:5f:b5:cd	2022-08-12 21:57:18.669524+00	x3000c0s3b0n0	Node	[{"IPAddress":""}]
1402ecdabb01		14:02:ec:da:bb:01	2022-08-12 21:57:19.18128+00	x3000c0s6b0n0	Node	[{"IPAddress":""}]
9440c93777b8	Configuration of this Manager Network Interface	94:40:c9:37:77:b8	2022-08-08 09:04:03.018083+00	x3000c0s6b0	NodeBMC	[]
9440c9370484	Configuration of this Manager Network Interface	94:40:c9:37:04:84	2022-08-08 09:04:04.910292+00	x3000c0s3b0	NodeBMC	[]
9440c95fb65d		94:40:c9:5f:b6:5d	2022-08-12 21:57:20.05464+00	x3000c0s8b0n0	Node	[{"IPAddress":""}]
9440c93777b9	Configuration of this Manager Network Interface	94:40:c9:37:77:b9	2022-08-08 09:04:03.018083+00	x3000c0s6b0	NodeBMC	[]
1402ecd976b9		14:02:ec:d9:76:b9	2022-08-12 21:57:18.483834+00	x3000c0s5b0n0	Node	[{"IPAddress":""}]
b42e99dfebc1		b4:2e:99:df:eb:c1	2022-08-08 10:06:53.841227+00	x3000c0s17b3	NodeBMC	[{"IPAddress":"10.254.1.39"}]
76c35e656b11	Ethernet Interface usb0	76:c3:5e:65:6b:11	2022-08-08 10:10:53.864448+00	x3000c0s17b3	NodeBMC	[]
1402ecd97c40	- kea	14:02:ec:d9:7c:40	2022-08-12 22:53:41.039747+00	x3000c0s4b0n0	Node	[{"IPAddress":"10.252.1.9"},{"IPAddress":"10.103.11.24"},{"IPAddress":"10.254.1.14"},{"IPAddress":"10.1.1.7"}]
b42e99dff361		b4:2e:99:df:f3:61	2022-08-08 10:06:31.546047+00	x3000c0s17b1	NodeBMC	[{"IPAddress":"10.254.1.23"}]
1402ecd97bc8	- kea	14:02:ec:d9:7b:c8	2022-08-12 22:53:40.818902+00	x3000c0s8b0n0	Node	[{"IPAddress":"10.252.1.5"},{"IPAddress":"10.103.11.20"},{"IPAddress":"10.254.1.6"},{"IPAddress":"10.1.1.3"}]
b42e99dfec49		b4:2e:99:df:ec:49	2022-08-08 10:06:58.992818+00	x3000c0s17b4	NodeBMC	[{"IPAddress":"10.254.1.41"}]
9440c9350306	Configuration of this Manager Network Interface	94:40:c9:35:03:06	2022-08-08 09:04:03.096256+00	x3000c0s5b0	NodeBMC	[]
0234e854d178	Ethernet Interface usb0	02:34:e8:54:d1:78	2022-08-08 10:11:10.210893+00	x3000c0s17b999	NodeBMC	[]
b42e99dfecf0	Ethernet Interface Lan2	b4:2e:99:df:ec:f0	2022-08-08 10:10:57.527819+00	x3000c0s17b2n0	Node	[]
b42e99dfecf1		b4:2e:99:df:ec:f1	2022-08-08 10:07:04.95533+00	x3000c0s17b2	NodeBMC	[{"IPAddress":"10.254.1.45"}]
0603a2227dee	Ethernet Interface usb0	06:03:a2:22:7d:ee	2022-08-08 10:10:57.527819+00	x3000c0s17b2	NodeBMC	[]
b42e99dfec48	Ethernet Interface Lan2	b4:2e:99:df:ec:48	2022-08-08 10:11:11.360506+00	x3000c0s17b4n0	Node	[]
aae05bbedf8e	Ethernet Interface usb0	aa:e0:5b:be:df:8e	2022-08-08 10:11:11.360506+00	x3000c0s17b4	NodeBMC	[]
b42e99dff360	Ethernet Interface Lan2	b4:2e:99:df:f3:60	2022-08-08 10:11:13.533084+00	x3000c0s17b1n0	Node	[]
46bb8cbe6e80	Ethernet Interface usb0	46:bb:8c:be:6e:80	2022-08-08 10:11:13.533084+00	x3000c0s17b1	NodeBMC	[]
ec0d9ac1b430		ec:0d:9a:c1:b4:30	2022-08-08 10:11:26.824952+00	x3000c0s19b0n0	Node	[]
1402ecdab890		14:02:ec:da:b8:90	2022-08-08 10:11:26.824952+00	x3000c0s19b0n0	Node	[]
1402ecdab891		14:02:ec:da:b8:91	2022-08-08 10:11:26.824952+00	x3000c0s19b0n0	Node	[]
1402ecd97bc9		14:02:ec:d9:7b:c9	2022-08-12 21:57:20.038719+00	x3000c0s8b0n0	Node	[{"IPAddress":""}]
9440c9350307	Configuration of this Manager Network Interface	94:40:c9:35:03:07	2022-08-08 09:04:03.096256+00	x3000c0s5b0	NodeBMC	[]
2ad9e3ffc3df	CSI Handoff MAC	2a:d9:e3:ff:c3:df	2022-08-08 10:45:24.275864+00	x3000c0s2b0n0	Node	[]
1402ecd97c41		14:02:ec:d9:7c:41	2022-08-12 21:57:19.886846+00	x3000c0s4b0n0	Node	[{"IPAddress":""}]
b42e99dff35f	Ethernet Interface Lan1	b4:2e:99:df:f3:5f	2022-08-18 16:38:21.13173+00	x3000c0s17b1n0	Node	[{"IPAddress":"10.252.1.16"}]
1402ecd97c89		14:02:ec:d9:7c:89	2022-08-12 21:57:19.352282+00	x3000c0s7b0n0	Node	[{"IPAddress":""}]
9440c95f9aa9		94:40:c9:5f:9a:a9	2022-08-12 21:57:19.368957+00	x3000c0s7b0n0	Node	[{"IPAddress":""}]
9440c9370485	Configuration of this Manager Network Interface	94:40:c9:37:04:85	2022-08-08 09:04:04.910292+00	x3000c0s3b0	NodeBMC	[]
9440c937875a	Configuration of this Manager Network Interface	94:40:c9:37:87:5a	2022-08-08 09:04:01.870005+00	x3000c0s8b0	NodeBMC	[]
9440c9376781	Configuration of this Manager Network Interface	94:40:c9:37:67:81	2022-08-08 10:11:26.824952+00	x3000c0s19b0	NodeBMC	[]
00cafef00d04	Configuration of this Manager USB Ethernet Interface available for access from Host.	00:ca:fe:f0:0d:04	2022-08-08 10:11:26.824952+00	x3000c0s19b0	NodeBMC	[]
9440c9376780		94:40:c9:37:67:80	2022-08-08 10:07:05.295791+00	x3000c0s19b0	NodeBMC	[{"IPAddress":"10.254.1.48"}]
1402ecdab999	CSI Handoff MAC	14:02:ec:da:b9:99	2022-08-12 21:57:20.277938+00	x3000c0s1b0n0	Node	[]
90e2ba93c937	CSI Handoff MAC	90:e2:ba:93:c9:37	2022-08-12 21:57:20.358331+00	x3000c0s1b0n0	Node	[]
9440c9376760	Configuration of this Manager Network Interface	94:40:c9:37:67:60	2022-08-08 09:04:04.527371+00	x3000c0s4b0	NodeBMC	[]
167ba5ee700e	CSI Handoff MAC	16:7b:a5:ee:70:0e	2022-08-08 10:45:23.281845+00	x3000c0s4b0n0	Node	[]
9440c9376761	Configuration of this Manager Network Interface	94:40:c9:37:67:61	2022-08-08 09:04:04.527371+00	x3000c0s4b0	NodeBMC	[]
1402ecd97c88	- kea	14:02:ec:d9:7c:88	2022-08-12 22:53:40.872591+00	x3000c0s7b0n0	Node	[{"IPAddress":"10.252.1.6"},{"IPAddress":"10.103.11.21"},{"IPAddress":"10.254.1.8"},{"IPAddress":"10.1.1.4"}]
9440c937875b	Configuration of this Manager Network Interface	94:40:c9:37:87:5b	2022-08-08 09:04:01.870005+00	x3000c0s8b0	NodeBMC	[]
1402ece1bda8	- kea	14:02:ec:e1:bd:a8	2022-08-18 22:15:03.792422+00	x3000c0s30b0n0	Node	[{"IPAddress":"10.252.1.13"},{"IPAddress":"10.103.11.143"},{"IPAddress":"10.1.1.11"},{"IPAddress":"10.254.1.22"}]
b47af1c212a8	- kea	b4:7a:f1:c2:12:a8	2022-08-18 22:15:03.961749+00	x3000c0s30b0	NodeBMC	[{"IPAddress":"10.254.1.21"}]
b42e99dfebbf		b4:2e:99:df:eb:bf	2022-08-18 16:38:21.218703+00	x3000c0s17b3n0	Node	[{"IPAddress":"10.252.1.17"}]
6ef1d21b446f	CSI Handoff MAC	6e:f1:d2:1b:44:6f	2022-08-08 10:45:23.220541+00	x3000c0s4b0n0	Node	[]
1622bc9b1387	CSI Handoff MAC	16:22:bc:9b:13:87	2022-08-08 10:45:23.266286+00	x3000c0s4b0n0	Node	[]
98039b3fb882		98:03:9b:3f:b8:82	2022-08-26 08:24:03.564901+00	x3000c0s4b0n0	Node	[]
9440c9370a2a	Configuration of this Manager Network Interface	94:40:c9:37:0a:2a	2022-08-08 09:04:03.810167+00	x3000c0s7b0	NodeBMC	[]
9440c9370a2b	Configuration of this Manager Network Interface	94:40:c9:37:0a:2b	2022-08-08 09:04:03.810167+00	x3000c0s7b0	NodeBMC	[]
1402ece1bda9		14:02:ec:e1:bd:a9	2022-08-18 22:15:03.86504+00	x3000c0s30b0n0	Node	[]
88e9a40284cc		88:e9:a4:02:84:cc	2022-08-18 22:15:03.908481+00	x3000c0s30b0n0	Node	[]
2aec3af4e3db	CSI Handoff MAC	2a:ec:3a:f4:e3:db	2022-08-12 21:57:19.503771+00	x3000c0s2b0n0	Node	[]
9440c95fb5df	CSI Handoff MAC	94:40:c9:5f:b5:df	2022-08-12 21:57:20.2948+00	x3000c0s1b0n0	Node	[]
90e2ba93c936	CSI Handoff MAC	90:e2:ba:93:c9:36	2022-08-12 21:57:20.343077+00	x3000c0s1b0n0	Node	[]
9440c95fb692		94:40:c9:5f:b6:92	2022-08-12 21:57:18.938769+00	x3000c0s9b0n0	Node	[{"IPAddress":""}]
3a46bc8ec7b7	CSI Handoff MAC	3a:46:bc:8e:c7:b7	2022-08-08 10:45:23.178922+00	x3000c0s4b0n0	Node	[]
9440c95fb693		94:40:c9:5f:b6:93	2022-08-12 21:57:18.904089+00	x3000c0s9b0n0	Node	[{"IPAddress":""}]
32f6a110b1b5	CSI Handoff MAC	32:f6:a1:10:b1:b5	2022-08-08 10:45:23.8976+00	x3000c0s6b0n0	Node	[]
5e7c2a472678	CSI Handoff MAC	5e:7c:2a:47:26:78	2022-08-08 10:45:23.949023+00	x3000c0s6b0n0	Node	[]
1402ecd97689		14:02:ec:d9:76:89	2022-08-12 21:57:18.88793+00	x3000c0s9b0n0	Node	[{"IPAddress":""}]
22905785c6a2	CSI Handoff MAC	22:90:57:85:c6:a2	2022-08-08 10:45:24.289066+00	x3000c0s2b0n0	Node	[]
4e08837a7dba	CSI Handoff MAC	4e:08:83:7a:7d:ba	2022-08-08 10:45:24.377867+00	x3000c0s2b0n0	Node	[]
9440c9377726	Configuration of this Manager Network Interface	94:40:c9:37:77:26	2022-08-08 09:04:02.201676+00	x3000c0s9b0	NodeBMC	[]
9440c9377727	Configuration of this Manager Network Interface	94:40:c9:37:77:27	2022-08-08 09:04:02.201676+00	x3000c0s9b0	NodeBMC	[]
9440c95f9aa8		94:40:c9:5f:9a:a8	2022-08-12 21:57:19.40156+00	x3000c0s7b0n0	Node	[{"IPAddress":""}]
a6b94c53fb85	CSI Handoff MAC	a6:b9:4c:53:fb:85	2022-08-08 10:45:24.526525+00	x3000c0s5b0n0	Node	[]
1a27951d655c	CSI Handoff MAC	1a:27:95:1d:65:5c	2022-08-08 10:45:24.574947+00	x3000c0s5b0n0	Node	[]
1e4ae280fbcf	CSI Handoff MAC	1e:4a:e2:80:fb:cf	2022-08-08 10:45:24.618478+00	x3000c0s5b0n0	Node	[]
be33d4ba40ee	CSI Handoff MAC	be:33:d4:ba:40:ee	2022-08-08 10:45:24.751903+00	x3000c0s3b0n0	Node	[]
fa83f692a973	CSI Handoff MAC	fa:83:f6:92:a9:73	2022-08-08 10:45:24.85526+00	x3000c0s3b0n0	Node	[]
90e2ba93c934	CSI Handoff MAC	90:e2:ba:93:c9:34	2022-08-12 21:57:20.312037+00	x3000c0s1b0n0	Node	[{"IPAddress":""}]
90e2ba93c935	CSI Handoff MAC	90:e2:ba:93:c9:35	2022-08-12 21:57:20.327791+00	x3000c0s1b0n0	Node	[]
c21f754694fb	CSI Handoff MAC	c2:1f:75:46:94:fb	2022-08-12 21:57:20.37346+00	x3000c0s1b0n0	Node	[]
1402ecd979e8	- kea	14:02:ec:d9:79:e8	2022-08-12 22:53:41.088036+00	x3000c0s3b0n0	Node	[{"IPAddress":"10.252.1.10"},{"IPAddress":"10.103.11.25"},{"IPAddress":"10.254.1.16"},{"IPAddress":"10.1.1.8"}]
92906879a1bd	CSI Handoff MAC	92:90:68:79:a1:bd	2022-08-12 21:57:18.444875+00	x3000c0s5b0n0	Node	[]
0acafef00d04	Configuration of this Manager USB Ethernet Interface available for access from Host.	0a:ca:fe:f0:0d:04	2022-08-08 09:04:01.19185+00	x3000c0s6b0	NodeBMC	[]
fed6a334236d	CSI Handoff MAC	fe:d6:a3:34:23:6d	2022-08-12 21:57:19.302255+00	x3000c0s7b0n0	Node	[]
ecebb83d8941		ec:eb:b8:3d:89:41	2022-08-15 22:00:14.685305+00	x3000m0	CabinetPDUController	[{"IPAddress":"10.254.1.26"}]
8a27b00d720e	CSI Handoff MAC	8a:27:b0:0d:72:0e	2022-08-12 21:57:19.521248+00	x3000c0s2b0n0	Node	[]
6e5ab7255b73	CSI Handoff MAC	6e:5a:b7:25:5b:73	2022-08-12 21:57:19.624018+00	x3000c0s2b0n0	Node	[]
ca71687aab76	CSI Handoff MAC	ca:71:68:7a:ab:76	2022-08-12 21:57:19.761054+00	x3000c0s4b0n0	Node	[]
82f00d193d09	CSI Handoff MAC	82:f0:0d:19:3d:09	2022-08-12 21:57:18.587246+00	x3000c0s3b0n0	Node	[]
6a8e9cd32c15	CSI Handoff MAC	6a:8e:9c:d3:2c:15	2022-08-12 21:57:18.685269+00	x3000c0s3b0n0	Node	[]
2aa7875c608a	CSI Handoff MAC	2a:a7:87:5c:60:8a	2022-08-08 10:45:23.861182+00	x3000c0s6b0n0	Node	[]
46cb3db8b3a1	CSI Handoff MAC	46:cb:3d:b8:b3:a1	2022-08-08 10:45:23.962668+00	x3000c0s6b0n0	Node	[]
462b5e36fa4c	CSI Handoff MAC	46:2b:5e:36:fa:4c	2022-08-08 10:45:24.30268+00	x3000c0s2b0n0	Node	[]
b6dc057e9645	CSI Handoff MAC	b6:dc:05:7e:96:45	2022-08-08 10:45:24.391191+00	x3000c0s2b0n0	Node	[]
fedb6746ed4a	CSI Handoff MAC	fe:db:67:46:ed:4a	2022-08-08 10:45:24.631069+00	x3000c0s5b0n0	Node	[]
eecccef9797a	CSI Handoff MAC	ee:cc:ce:f9:79:7a	2022-08-08 10:45:24.767933+00	x3000c0s3b0n0	Node	[]
1e18dea57c1c	CSI Handoff MAC	1e:18:de:a5:7c:1c	2022-08-08 10:45:24.86968+00	x3000c0s3b0n0	Node	[]
6a98b19957b3	CSI Handoff MAC	6a:98:b1:99:57:b3	2022-08-12 21:57:18.838187+00	x3000c0s9b0n0	Node	[]
72552b5fa606	CSI Handoff MAC	72:55:2b:5f:a6:06	2022-08-12 21:57:19.071304+00	x3000c0s6b0n0	Node	[]
be9a4443005b	CSI Handoff MAC	be:9a:44:43:00:5b	2022-08-12 21:57:19.121879+00	x3000c0s6b0n0	Node	[]
1402ecdab818	- kea	14:02:ec:da:b8:18	2022-08-12 22:53:41.138924+00	x3000c0s2b0n0	Node	[{"IPAddress":"10.252.1.11"},{"IPAddress":"10.103.11.26"},{"IPAddress":"10.254.1.18"},{"IPAddress":"10.1.1.9"}]
1402ecd97688	- kea	14:02:ec:d9:76:88	2022-08-12 22:53:40.762663+00	x3000c0s9b0n0	Node	[{"IPAddress":"10.252.1.4"},{"IPAddress":"10.103.11.19"},{"IPAddress":"10.254.1.4"},{"IPAddress":"10.1.1.2"}]
1402ecdabb00	- kea	14:02:ec:da:bb:00	2022-08-12 22:53:40.926887+00	x3000c0s6b0n0	Node	[{"IPAddress":"10.252.1.7"},{"IPAddress":"10.1.1.5"},{"IPAddress":"10.103.11.22"},{"IPAddress":"10.254.1.10"}]
aa25f0574f3f	CSI Handoff MAC	aa:25:f0:57:4f:3f	2022-08-12 21:57:19.778312+00	x3000c0s4b0n0	Node	[]
0040a6831b53		00:40:a6:83:1b:53	2022-08-15 22:45:06.203982+00	x3000c0r15b0	RouterBMC	[{"IPAddress":"10.254.1.27"}]
b6139b024bbd	CSI Handoff MAC	b6:13:9b:02:4b:bd	2022-08-12 21:57:19.829493+00	x3000c0s4b0n0	Node	[]
9a4ced6029d6	CSI Handoff MAC	9a:4c:ed:60:29:d6	2022-08-12 21:57:20.193351+00	x3000c0s1b0n0	Node	[]
7a125e5d38c4	CSI Handoff MAC	7a:12:5e:5d:38:c4	2022-08-12 21:57:20.388574+00	x3000c0s1b0n0	Node	[]
9440c95fb5de	CSI Handoff MAC	94:40:c9:5f:b5:de	2022-08-12 21:57:20.42095+00	x3000c0s1b0n0	Node	[]
7a7a3493347f	CSI Handoff MAC	7a:7a:34:93:34:7f	2022-08-12 21:57:18.324163+00	x3000c0s5b0n0	Node	[]
8ea4eaccf56c	CSI Handoff MAC	8e:a4:ea:cc:f5:6c	2022-08-12 21:57:18.374441+00	x3000c0s5b0n0	Node	[]
98039b7fc060		98:03:9b:7f:c0:60	2022-08-12 21:57:18.35583+00	x3000c0s5b0n0	Node	[{"IPAddress":""}]
88e9a4029414		88:e9:a4:02:94:14	2022-08-18 22:15:03.881173+00	x3000c0s30b0n0	Node	[]
06b181b01d08	CSI Handoff MAC	06:b1:81:b0:1d:08	2022-08-12 21:57:18.424588+00	x3000c0s5b0n0	Node	[]
d2b75964faf7	CSI Handoff MAC	d2:b7:59:64:fa:f7	2022-08-12 21:57:18.603277+00	x3000c0s3b0n0	Node	[]
e6c014b7a4ec	CSI Handoff MAC	e6:c0:14:b7:a4:ec	2022-08-12 21:57:18.702086+00	x3000c0s3b0n0	Node	[]
c6cbdf90ea55	CSI Handoff MAC	c6:cb:df:90:ea:55	2022-08-12 21:57:19.039843+00	x3000c0s6b0n0	Node	[]
9260954b4b5e	CSI Handoff MAC	92:60:95:4b:4b:5e	2022-08-12 21:57:19.146042+00	x3000c0s6b0n0	Node	[]
66c6e763350f	CSI Handoff MAC	66:c6:e7:63:35:0f	2022-08-12 21:57:19.602814+00	x3000c0s2b0n0	Node	[]
7a3cbaef10a0	CSI Handoff MAC	7a:3c:ba:ef:10:a0	2022-08-12 21:57:19.846883+00	x3000c0s4b0n0	Node	[]
9eaddeb5dcdc	CSI Handoff MAC	9e:ad:de:b5:dc:dc	2022-08-12 21:57:19.989179+00	x3000c0s8b0n0	Node	[]
0a928a0defca	CSI Handoff MAC	0a:92:8a:0d:ef:ca	2022-08-12 21:57:20.209171+00	x3000c0s1b0n0	Node	[]
\.


--
-- Data for Name: component_group_members; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.component_group_members (component_id, group_id, group_namespace, joined_at) FROM stdin;
\.


--
-- Data for Name: component_groups; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.component_groups (id, name, description, tags, annotations, type, namespace, exclusive_group_identifier) FROM stdin;
\.


--
-- Data for Name: components; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.components (id, type, state, admin, enabled, flag, role, nid, subtype, nettype, arch, disposition, subrole, class, reservation_disabled, locked) FROM stdin;
x3000c0s9e0	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s30b0n0	Node	Standby	DvsAvailable	t	Alert	Management	100010		Sling	X86		Worker	River	f	f
x3000c0s3b0n0	Node	Ready		t	OK	Management	100007		Sling	X86		Master	River	f	t
x3000m1	CabinetPDUController	Ready		t	OK		-1		Sling	X86				f	f
x3000c0s17e2	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s17b2	NodeBMC	Ready		t	OK		-1		Sling	X86			River	f	f
x3000c0s17b999	NodeBMC	Ready		t	OK		-1		Sling	X86			River	f	f
x3000c0s17e4	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s17b4n0	Node	On		t	OK	Compute	4		Sling	X86			River	f	f
x3000c0s17b4	NodeBMC	Ready		t	OK		-1		Sling	X86			River	f	f
x3000c0s17e1	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s17b1n0	Node	On		t	OK	Compute	1		Sling	X86			River	f	f
x3000c0s17b1	NodeBMC	Ready		t	OK		-1		Sling	X86			River	f	f
x3000c0s19e0	NodeEnclosure	On		t	Warning		-1		Sling	X86			River	f	f
x3000c0s19b0n0	Node	On		t	OK	Application	49168992		Sling	X86		UAN	River	f	f
x3000c0s19b0	NodeBMC	Ready		t	OK		-1		Sling	X86			River	f	f
x3000c0s7b0n0	Node	Ready		t	OK	Management	100003		Sling	X86		Storage	River	f	t
x3000c0s1b0n0	Node	Populated		t	OK	Management	100009		Sling	X86		Master	River	f	t
x3000c0s17e3	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s9b0	NodeBMC	Ready		t	OK	Management	-1		Sling	X86			River	f	t
x3000c0s17b3n0	Node	On		t	OK	Compute	3		Sling	X86			River	f	f
x3000c0s7e0	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s17b3	NodeBMC	Ready		t	OK		-1		Sling	X86			River	f	f
x3000c0s7b0	NodeBMC	Ready		t	OK	Management	-1		Sling	X86			River	f	t
x3000c0s9b0n0	Node	Ready		t	OK	Management	100001		Sling	X86		Storage	River	f	t
x3000c0s8e0	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s6b0n0	Node	Ready		t	OK	Management	100004		Sling	X86		Worker	River	f	t
x3000c0s8b0	NodeBMC	Ready		t	OK	Management	-1		Sling	X86			River	f	t
x3000c0s3e0	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s3b0	NodeBMC	Ready		t	OK	Management	-1		Sling	X86			River	f	t
x3000c0s17b2n0	Node	On		t	OK	Compute	2		Sling	X86			River	f	f
x3000c0r15e0	HSNBoard	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s4b0n0	Node	Ready	DvsAvailable	t	OK	Management	100006		Sling	X86		Worker	River	f	t
x3000c0s2b0n0	Node	Ready		t	OK	Management	100008		Sling	X86		Master	River	f	t
x3000c0s2e0	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s5b0n0	Node	Ready	DvsAvailable	t	OK	Management	100005		Sling	X86		Worker	River	f	t
x3000c0s2b0	NodeBMC	Ready		t	OK	Management	-1		Sling	X86			River	f	t
x3000c0r15b0	RouterBMC	Ready		t	OK		-1		Sling	X86			River	f	f
x3000c0s5e0	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s6e0	NodeEnclosure	Off		t	Warning		-1		Sling	X86			River	f	f
x3000c0s5b0	NodeBMC	Ready		t	OK	Management	-1		Sling	X86			River	f	t
x3000c0s6b0	NodeBMC	Ready		t	OK	Management	-1		Sling	X86			River	f	t
x3000c0s30e0	NodeEnclosure	On		t	Warning		-1		Sling	X86			River	f	f
x3000c0s8b0n0	Node	Ready		t	OK	Management	100002		Sling	X86		Storage	River	f	t
x3000c0s4e0	NodeEnclosure	On		t	OK		-1		Sling	X86			River	f	f
x3000c0s30b0	NodeBMC	Ready		t	OK		-1		Sling	X86			River	f	f
x3000c0s4b0	NodeBMC	Ready		t	OK	Management	-1		Sling	X86			River	f	t
\.


--
-- Data for Name: discovery_status; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.discovery_status (id, status, last_update, details) FROM stdin;
0	NotStarted	2022-08-08 08:59:50.240743+00	{}
\.


--
-- Data for Name: hsn_interfaces; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.hsn_interfaces (nic, macaddr, hsn, node, ipaddr, last_update) FROM stdin;
\.


--
-- Data for Name: hwinv_by_fru; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.hwinv_by_fru (fru_id, type, subtype, serial_number, part_number, manufacturer, fru_info) FROM stdin;
Memory.Samsung.M393A2K40DB3CWE.373B86FF	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B86FF"}
NodeEnclosure.HPE.MXQ03000T9	NodeEnclosure					{"AssetTag":"","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000T9","SKU":"P18606-B21"}
FRUIDforx3000c0s2b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7HS	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDM7HS","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Memory.Samsung.M393A2K40DB3CWE.373B889A	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B889A"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNEK6	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNEK6","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Node.HPE.MXQ03000TK	Node					{"AssetTag":"","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TK","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-33303030544B"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F2D6	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F2D6"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F26F	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F26F"}
FRUIDforx3000c0s9b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7302P 16-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":16,"TotalThreads":32,"Oem":{}}
Memory.Samsung.M393A2K40DB3CWE.373B89E3	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B89E3"}
Memory.Samsung.M393A2K40DB3CWE.373B9940	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B9940"}
Memory.Samsung.M393A2K40DB3CWE.373BA9FD	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BA9FD"}
FRUIDforx3000c0s30b0n0g0k0	Drive					{"Manufacturer":"","SerialNumber":"Y160A00LTDS8","PartNumber":"","Model":"KCD6XLUL1T92","SKU":"","CapacityBytes":1920383000000,"Protocol":"NVMe","MediaType":"SSD","RotationSpeedRPM":0,"BlockSizeBytes":0,"CapableSpeedGbs":0,"FailurePredicted":false,"EncryptionAbility":"","EncryptionStatus":"","NegotiatedSpeedGbs":0,"PredictedMediaLifeLeftPercent":100}
NodeHsnNic.AH201041431A.REE2039L34069	NodeHsnNic					{"Manufacturer":"","Model":"","PartNumber":"AH2010414-31  A","SerialNumber":"REE2039L34069"}
FRUIDforx3000c0s30b0n0h1	NodeHsnNic					{"Manufacturer":"","Model":"HPE Ethernet 100Gb 1-port QSFP28 PCIe3 x16 MCX515A-CCAT Adapter","PartNumber":"","SerialNumber":"IL204100QR"}
FRUIDforx3000c0s30b0n0h2	NodeHsnNic					{"Manufacturer":"","Model":"HPE Ethernet 100Gb 1-port QSFP28 PCIe3 x16 MCX515A-CCAT Adapter","PartNumber":"","SerialNumber":"IL204100Q5"}
FRUIDforx3000c0s30b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
NodeEnclosure.HPE.MXQ03000TC	NodeEnclosure					{"AssetTag":"","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TC","SKU":"P18606-B21"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7AY	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDN7AY","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7FR	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDN7FR","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F346	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F346"}
Memory.Samsung.M393A2K40DB3CWE.373B8628	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B8628"}
Memory.Samsung.M393A2K40DB3CWE.373B85DD	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B85DD"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F330	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F330"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F32F	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F32F"}
FRUIDforx3000c0r15e0	HSNBoard					{"AssetTag":"","ChassisType":"Enclosure","Model":"101878104","Manufacturer":"HPE","PartNumber":"BC19300005.","SerialNumber":"","SKU":""}
FRUIDforx3000c0r15b0	RouterBMC					{"ManagerType":"EnclosureManager","Model":"","Manufacturer":"","PartNumber":"","SerialNumber":""}
FRUIDforx3000c0s9b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
FRUIDforx3000c0s8b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
FRUIDforx3000c0s4b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
Memory.Samsung.M393A2K40DB3CWE.373B8990	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B8990"}
NodeEnclosure.HPE.MXQ03000TJ	NodeEnclosure					{"AssetTag":"                                ","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TJ","SKU":"P18606-B21"}
FRUIDforx3000c0s6b0n0d14	Memory					{"BusWidthBits":72,"CapacityMiB":0,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","MemoryType":"DRAM","OperatingSpeedMhz":0,"SerialNumber":"NOT AVAILABLE   "}
Memory.Samsung.M393A2K40DB3CWE.373B898F	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B898F"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDMF3J	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDMF3J","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
FRUIDforx3000c0s6b0n0d3	Memory					{"BusWidthBits":72,"CapacityMiB":0,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","MemoryType":"DRAM","OperatingSpeedMhz":0,"SerialNumber":"NOT AVAILABLE   "}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFPE	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNFPE","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
FRUIDforx3000c0s6b0n0d8	Memory					{"BusWidthBits":72,"CapacityMiB":0,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","MemoryType":"DRAM","OperatingSpeedMhz":0,"SerialNumber":"NOT AVAILABLE   "}
Memory.Hynix.HMA84GR7CJR4NXN.3444F300	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F300"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F13F	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F13F"}
Memory.Samsung.M393A4K40DB3CWE.15B89403	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A4K40DB3-CWE","RankCount":2,"SerialNumber":"15B89403"}
FRUIDforx3000c0s5b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
Memory.Samsung.M393A2K40DB3CWE.373BAAE9	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BAAE9"}
Memory.Samsung.M393A2K40DB3CWE.373B9A63	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B9A63"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F2CC	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F2CC"}
Memory.Samsung.M393A2K40DB3CWE.373B8552	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B8552"}
Memory.Samsung.M393A2K40DB3CWE.373B993A	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B993A"}
Memory.Samsung.M393A2K40DB3CWE.373B8991	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B8991"}
NodeEnclosure.HPE.MXQ14808WM	NodeEnclosure					{"AssetTag":"                                ","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus v2","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ14808WM","SKU":"P38471-B21"}
NodeEnclosurePowerSupply.DELTA.5XLNU0H4DF3067	NodeEnclosurePowerSupply					{"Manufacturer":"DELTA","SerialNumber":"5XLNU0H4DF3067","Model":"P38995-B21","PartNumber":"","PowerCapacityWatts":800,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
FRUIDforx3000c0s6b0n0d10	Memory					{"BusWidthBits":72,"CapacityMiB":0,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","MemoryType":"DRAM","OperatingSpeedMhz":0,"SerialNumber":"NOT AVAILABLE   "}
FRUIDforx3000c0s6b0n0d1	Memory					{"BusWidthBits":72,"CapacityMiB":0,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","MemoryType":"DRAM","OperatingSpeedMhz":0,"SerialNumber":"NOT AVAILABLE   "}
Memory.Hynix.HMA84GR7CJR4NXN.3444F2CF	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F2CF"}
NodeEnclosurePowerSupply.DELTA.5XLNU0H4DF303Y	NodeEnclosurePowerSupply					{"Manufacturer":"DELTA","SerialNumber":"5XLNU0H4DF303Y","Model":"P38995-B21","PartNumber":"","PowerCapacityWatts":800,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F140	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F140"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F108	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F108"}
FRUIDforx3000c0s6b0n0d12	Memory					{"BusWidthBits":72,"CapacityMiB":0,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","MemoryType":"DRAM","OperatingSpeedMhz":0,"SerialNumber":"NOT AVAILABLE   "}
FRUIDforx3000c0s6b0n0d5	Memory					{"BusWidthBits":72,"CapacityMiB":0,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","MemoryType":"DRAM","OperatingSpeedMhz":0,"SerialNumber":"NOT AVAILABLE   "}
Memory.Hynix.HMA84GR7CJR4NXN.3444F141	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F141"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F10B	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F10B"}
NodeEnclosure.HPE.MXQ03000TB	NodeEnclosure					{"AssetTag":"","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TB","SKU":"P18606-B21"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7NQ	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDM7NQ","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDME6K	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDME6K","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Node.HPE.MXQ03000TB	Node					{"AssetTag":"","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TB","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-333030305442"}
FRUIDforx3000c0s7b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7302P 16-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":16,"TotalThreads":32,"Oem":{}}
Memory.Hynix.HMA84GR7CJR4NXN.3444F0F3	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F0F3"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNAC3	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNAC3","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Memory.Samsung.M393A2K40DB3CWE.373B9ADC	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B9ADC"}
Memory.Samsung.M393A2K40DB3CWE.373BAB2E	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BAB2E"}
Node.HPE.MXQ03000T9	Node					{"AssetTag":"","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000T9","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-333030305439"}
Memory.Samsung.M393A2K40DB3CWE.373BA7F7	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BA7F7"}
Memory.Samsung.M393A2K40DB3CWE.373B9939	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B9939"}
FRUIDforx3000c0s8b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7302P 16-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":16,"TotalThreads":32,"Oem":{}}
Memory.Samsung.M393A2K40DB3CWE.373B8995	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B8995"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F16D	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F16D"}
FRUIDforx3000c0s6b0n0d7	Memory					{"BusWidthBits":72,"CapacityMiB":0,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","MemoryType":"DRAM","OperatingSpeedMhz":0,"SerialNumber":"NOT AVAILABLE   "}
FRUIDforx3000c0s6b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
NodeEnclosure.HPE.MXQ03000TK	NodeEnclosure					{"AssetTag":"","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TK","SKU":"P18606-B21"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFQV	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNFQV","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Memory.Samsung.M393A2K40DB3CWE.373B89DD	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B89DD"}
Node.HPE.MXQ03000TC	Node					{"AssetTag":"","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TC","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-333030305443"}
FRUIDforx3000c0s2b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7302P 16-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":16,"TotalThreads":32,"Oem":{}}
Memory.Samsung.M393A2K40DB3CWE.373B9AE1	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B9AE1"}
Memory.Samsung.M393A2K40DB3CWE.373B85D7	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B85D7"}
Memory.Samsung.M393A2K40DB3CWE.373BABE8	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BABE8"}
Memory.Samsung.M393A2K40DB3CWE.373BABEC	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BABEC"}
Memory.Samsung.M393A2K40DB3CWE.373BAB28	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BAB28"}
FRUIDforx3000c0s7b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
Memory.Samsung.M393A2K40DB3CWE.373B99E1	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B99E1"}
FRUIDforx3000c0s3b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
Node.HPE.MXQ14808WM	Node					{"AssetTag":"                                ","BiosVersion":"A43 v2.40 (02/23/2021)","Model":"ProLiant DL325 Gen10 Plus v2","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ14808WM","SKU":"P38471-B21","SystemType":"Physical","UUID":"34383350-3137-584D-5131-34383038574D"}
NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	NodeEnclosure					{"AssetTag":"01234567890123456789AB","ChassisType":"RackMount","Model":"H262-Z63-YF","Manufacturer":"Cray Inc.","PartNumber":"6NH262Z63MR-YF-100","SerialNumber":"GKG1NC412A0063","SKU":"01234567890123456789AB"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA9A	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA9A"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAAC	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAAC"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD9	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAD9"}
FRUIDforx3000c0s17e3t0	NodeEnclosurePowerSupply					{"Manufacturer":"","SerialNumber":"","Model":"","PartNumber":"","PowerCapacityWatts":0,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":""}
FRUIDforx3000c0s17e3t1	NodeEnclosurePowerSupply					{"Manufacturer":"","SerialNumber":"","Model":"","PartNumber":"","PowerCapacityWatts":0,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":""}
Node.CrayInc.102348206.GKG1NC412A006303	Node					{"AssetTag":"Free form asset tag","BiosVersion":"C20","Model":"H262-Z63-YF","Manufacturer":"Cray Inc.","PartNumber":"102348206","SerialNumber":"GKG1NC412A006303","SKU":"01234567890123456789AB","SystemType":"Physical","UUID":"70518000-5ab2-11eb-8000-b42e99dfebbf"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA77	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA77"}
Memory.Samsung.M393A2K40DB3CWE.373B86A3	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B86A3"}
Memory.Samsung.M393A2K40DB3CWE.373B97AB	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B97AB"}
FRUIDforx3000c0s4b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7502P 32-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":32,"TotalThreads":64,"Oem":{}}
Memory.Hynix.HMA84GR7CJR4NXN.3444F2E2	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F2E2"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F25B	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F25B"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F263	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F263"}
Memory.Samsung.M393A2K40DB3CWE.373B8939	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B8939"}
Memory.Samsung.M393A2K40DB3CWE.373B893A	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B893A"}
FRUIDforx3000c0s30b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3700,"Model":"AMD EPYC 7713P 64-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f1100a0fbff178b","MicrocodeInfo":"","Step":"1","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":{}}
Memory.Hynix.HMA84GR7DJR4NXN.8580127F	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7DJR4N-XN","RankCount":2,"SerialNumber":"8580127F"}
Memory.Hynix.HMA84GR7DJR4NXN.8580117F	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7DJR4N-XN","RankCount":2,"SerialNumber":"8580117F"}
Memory.Hynix.HMA84GR7DJR4NXN.858011A5	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7DJR4N-XN","RankCount":2,"SerialNumber":"858011A5"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD1	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAD1"}
Memory.Samsung.M393A2K40DB3CWE.373B97AE	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B97AE"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAE1	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAE1"}
Memory.Hynix.HMA84GR7DJR4NXN.858011EC	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7DJR4N-XN","RankCount":2,"SerialNumber":"858011EC"}
FRUIDforx3000c0s17e2t0	NodeEnclosurePowerSupply					{"Manufacturer":"","SerialNumber":"","Model":"","PartNumber":"","PowerCapacityWatts":0,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":""}
FRUIDforx3000c0s17e2t1	NodeEnclosurePowerSupply					{"Manufacturer":"","SerialNumber":"","Model":"","PartNumber":"","PowerCapacityWatts":0,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":""}
Memory.Hynix.HMA84GR7CJR4NXN.3444F24F	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F24F"}
NodeEnclosure.HPE.MXQ03000T8	NodeEnclosure					{"AssetTag":"","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000T8","SKU":"P18606-B21"}
Memory.Hynix.HMA84GR7DJR4NXN.85801261	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7DJR4N-XN","RankCount":2,"SerialNumber":"85801261"}
Memory.Hynix.HMA84GR7DJR4NXN.85801263	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7DJR4N-XN","RankCount":2,"SerialNumber":"85801263"}
Memory.Hynix.HMA84GR7DJR4NXN.8580127C	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7DJR4N-XN","RankCount":2,"SerialNumber":"8580127C"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAAE	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAAE"}
FRUIDforx3000c0s17b999	NodeBMC					{"ManagerType":"BMC","Model":"6532210600","Manufacturer":"","PartNumber":"","SerialNumber":""}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7DN	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDN7DN","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7HF	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDM7HF","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Memory.Hynix.HMA84GR7DJR4NXN.858011E4	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7DJR4N-XN","RankCount":2,"SerialNumber":"858011E4"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADF	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBADF"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADA	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBADA"}
FRUIDforx3000c0s17b3	NodeBMC					{"ManagerType":"BMC","Model":"410810600","Manufacturer":"","PartNumber":"","SerialNumber":""}
Memory.Samsung.M393A2K40DB3CWE.373B86A7	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B86A7"}
Node.CrayInc.102348206.GKG1NC412A006302	Node					{"AssetTag":"Free form asset tag","BiosVersion":"C20","Model":"H262-Z63-YF","Manufacturer":"Cray Inc.","PartNumber":"102348206","SerialNumber":"GKG1NC412A006302","SKU":"01234567890123456789AB","SystemType":"Physical","UUID":"70518000-5ab2-11eb-8000-b42e99dfecef"}
Processor.AdvancedMicroDevicesInc.2B4AD1868628009	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3350,"Model":"AMD EPYC 7702 64-Core Processor                ","SerialNumber":"2B4AD1868628009","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"AMD Zen Processor Family","EffectiveModel":"0x31","IdentificationRegisters":"178bfbff00830f10","MicrocodeInfo":"","Step":"0x0","VendorID":"AuthenticAMD"},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":null}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB654	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB654"}
Node.HPE.MXQ03000TJ	Node					{"AssetTag":"                                ","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TJ","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-33303030544A"}
Memory.Samsung.M393A2K40DB3CWE.373B9680	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B9680"}
FRUIDforx3000c0s17b2	NodeBMC					{"ManagerType":"BMC","Model":"410810600","Manufacturer":"","PartNumber":"","SerialNumber":""}
FRUIDforx3000c0s17e4t0	NodeEnclosurePowerSupply					{"Manufacturer":"","SerialNumber":"","Model":"","PartNumber":"","PowerCapacityWatts":0,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":""}
FRUIDforx3000c0s17e4t1	NodeEnclosurePowerSupply					{"Manufacturer":"","SerialNumber":"","Model":"","PartNumber":"","PowerCapacityWatts":0,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":""}
Node.CrayInc.102348206.GKG1NC412A006304	Node					{"AssetTag":"Free form asset tag","BiosVersion":"C20","Model":"H262-Z63-YF","Manufacturer":"Cray Inc.","PartNumber":"102348206","SerialNumber":"GKG1NC412A006304","SKU":"01234567890123456789AB","SystemType":"Physical","UUID":"70518000-5ab2-11eb-8000-b42e99dfec47"}
Processor.AdvancedMicroDevicesInc.2B4AD186862800A	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3350,"Model":"AMD EPYC 7702 64-Core Processor                ","SerialNumber":"2B4AD186862800A","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"AMD Zen Processor Family","EffectiveModel":"0x31","IdentificationRegisters":"178bfbff00830f10","MicrocodeInfo":"","Step":"0x0","VendorID":"AuthenticAMD"},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":null}
Processor.AdvancedMicroDevicesInc.2B4AD186862800B	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3350,"Model":"AMD EPYC 7702 64-Core Processor                ","SerialNumber":"2B4AD186862800B","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"AMD Zen Processor Family","EffectiveModel":"0x31","IdentificationRegisters":"178bfbff00830f10","MicrocodeInfo":"","Step":"0x0","VendorID":"AuthenticAMD"},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":null}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB677	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB677"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6E1	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB6E1"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB641	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB641"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB655	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB655"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB62D	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB62D"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA76	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA76"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA91	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA91"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA73	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA73"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB653	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB653"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB62E	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB62E"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA74	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA74"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB759	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB759"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6A5	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB6A5"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB682	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB682"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB69C	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB69C"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB698	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB698"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB695	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB695"}
FRUIDforx3000c0s17b4	NodeBMC					{"ManagerType":"BMC","Model":"410810600","Manufacturer":"","PartNumber":"","SerialNumber":""}
NodeEnclosure.HPE.MXQ03000TH	NodeEnclosure					{"AssetTag":"","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TH","SKU":"P18606-B21"}
FRUIDforx3000c0s5b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7502P 32-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":32,"TotalThreads":64,"Oem":{}}
Memory.Hynix.HMA84GR7CJR4NXN.3444F25E	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F25E"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F295	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F295"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F25F	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F25F"}
FRUIDforx3000c0s6b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7502P 32-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":32,"TotalThreads":64,"Oem":{}}
FRUIDforx3000c0s17e1t0	NodeEnclosurePowerSupply					{"Manufacturer":"","SerialNumber":"","Model":"","PartNumber":"","PowerCapacityWatts":0,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":""}
FRUIDforx3000c0s17e1t1	NodeEnclosurePowerSupply					{"Manufacturer":"","SerialNumber":"","Model":"","PartNumber":"","PowerCapacityWatts":0,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":""}
Node.CrayInc.102348206.GKG1NC412A006301	Node					{"AssetTag":"Free form asset tag","BiosVersion":"C20","Model":"H262-Z63-YF","Manufacturer":"Cray Inc.","PartNumber":"102348206","SerialNumber":"GKG1NC412A006301","SKU":"01234567890123456789AB","SystemType":"Physical","UUID":"70518000-5ab2-11eb-8000-b42e99dff35f"}
Processor.AdvancedMicroDevicesInc.2B4AD1868628058	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3350,"Model":"AMD EPYC 7702 64-Core Processor                ","SerialNumber":"2B4AD1868628058","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"AMD Zen Processor Family","EffectiveModel":"0x31","IdentificationRegisters":"178bfbff00830f10","MicrocodeInfo":"","Step":"0x0","VendorID":"AuthenticAMD"},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":null}
Processor.AdvancedMicroDevicesInc.2B4AD186862805A	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3350,"Model":"AMD EPYC 7702 64-Core Processor                ","SerialNumber":"2B4AD186862805A","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"AMD Zen Processor Family","EffectiveModel":"0x31","IdentificationRegisters":"178bfbff00830f10","MicrocodeInfo":"","Step":"0x0","VendorID":"AuthenticAMD"},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":null}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADD	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBADD"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADC	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBADC"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5C	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA5C"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6F	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA6F"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAC4	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAC4"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBACC	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBACC"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA71	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA71"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5F	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA5F"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5E	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA5E"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD6	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAD6"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA60	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA60"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA92	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA92"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5D	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA5D"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5B	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA5B"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6E	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA6E"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6C	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA6C"}
FRUIDforx3000c0s17b1	NodeBMC					{"ManagerType":"BMC","Model":"410810600","Manufacturer":"","PartNumber":"","SerialNumber":""}
NodeEnclosure.HPE.MXQ03000TG	NodeEnclosure					{"AssetTag":"                                ","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TG","SKU":"P18606-B21"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNAER	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNAER","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFPR	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNFPR","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Node.HPE.MXQ03000TG	Node					{"AssetTag":"                                ","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TG","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-333030305447"}
FRUIDforx3000c0s19b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7502P 32-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":32,"TotalThreads":64,"Oem":{}}
Memory.Hynix.HMA84GR7CJR4NXN.3444F347	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F347"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F266	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F266"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F349	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F349"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F269	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F269"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F256	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F256"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F30B	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F30B"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F167	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F167"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F348	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F348"}
FRUIDforx3000c0s19b0	NodeBMC					{"ManagerType":"BMC","Model":"iLO 5","Manufacturer":"","PartNumber":"","SerialNumber":""}
Memory.Samsung.M393A2K40DB3CWE.373BAC2E	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BAC2E"}
NodeEnclosure.HPE.MXQ03000TD	NodeEnclosure					{"AssetTag":"","ChassisType":"RackMount","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TD","SKU":"P18606-B21"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7K4	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDN7K4","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFRM	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNFRM","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Memory.Samsung.M393A2K40DB3CWE.373BABE3	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BABE3"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNERP	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNERP","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA98	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA98"}
Processor.AdvancedMicroDevicesInc.2B4AD1868628054	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3350,"Model":"AMD EPYC 7702 64-Core Processor                ","SerialNumber":"2B4AD1868628054","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"AMD Zen Processor Family","EffectiveModel":"0x31","IdentificationRegisters":"178bfbff00830f10","MicrocodeInfo":"","Step":"0x0","VendorID":"AuthenticAMD"},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":null}
Processor.AdvancedMicroDevicesInc.2B4AD1868628055	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3350,"Model":"AMD EPYC 7702 64-Core Processor                ","SerialNumber":"2B4AD1868628055","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"AMD Zen Processor Family","EffectiveModel":"0x31","IdentificationRegisters":"178bfbff00830f10","MicrocodeInfo":"","Step":"0x0","VendorID":"AuthenticAMD"},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":null}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA3E	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA3E"}
NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFPZ	NodeEnclosurePowerSupply					{"Manufacturer":"LTEON","SerialNumber":"5WBXK0FLLDNFPZ","Model":"865408-B21","PartNumber":"","PowerCapacityWatts":500,"PowerInputWatts":0,"PowerOutputWatts":0,"PowerSupplyType":"AC"}
Node.HPE.MXQ03000TH	Node					{"AssetTag":"","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TH","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-333030305448"}
Memory.Hynix.HMA84GR7CJR4NXN.3444F306	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":32768,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA84GR7CJR4N-XN","RankCount":2,"SerialNumber":"3444F306"}
Node.HPE.MXQ03000T8	Node					{"AssetTag":"","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000T8","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-333030305438"}
Node.HPE.MXQ03000TD	Node					{"AssetTag":"","BiosVersion":"A43 v1.38 (10/30/2020)","Model":"ProLiant DL325 Gen10 Plus","Manufacturer":"HPE","PartNumber":"","SerialNumber":"MXQ03000TD","SKU":"P18606-B21","SystemType":"Physical","UUID":"36383150-3630-584D-5130-333030305444"}
FRUIDforx3000c0s3b0n0p0	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3100,"Model":"AMD EPYC 7302P 16-Core Processor               ","SerialNumber":"","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"107","EffectiveModel":"1","IdentificationRegisters":"0x0f100083fbff178b","MicrocodeInfo":"","Step":"0","VendorID":"Advanced Micro Devices, Inc."},"ProcessorType":"CPU","TotalCores":16,"TotalThreads":32,"Oem":{}}
Memory.Samsung.M393A2K40DB3CWE.373BAB29	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BAB29"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA75	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA75"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAB3	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAB3"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAE0	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBAE0"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBACE	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBACE"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA33	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADBA33"}
Processor.AdvancedMicroDevicesInc.2B4AD186862800E	Processor					{"InstructionSet":"x86-64","Manufacturer":"Advanced Micro Devices, Inc.","MaxSpeedMHz":3350,"Model":"AMD EPYC 7702 64-Core Processor                ","SerialNumber":"2B4AD186862800E","PartNumber":"","ProcessorArchitecture":"x86","ProcessorId":{"EffectiveFamily":"AMD Zen Processor Family","EffectiveModel":"0x31","IdentificationRegisters":"178bfbff00830f10","MicrocodeInfo":"","Step":"0x0","VendorID":"AuthenticAMD"},"ProcessorType":"CPU","TotalCores":64,"TotalThreads":128,"Oem":null}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB640	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB640"}
Memory.Samsung.M393A2K40DB3CWE.373B893B	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B893B"}
Memory.Samsung.M393A2K40DB3CWE.373BABE9	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373BABE9"}
Memory.Samsung.M393A2K40DB3CWE.373B86A8	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B86A8"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB633	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB633"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB678	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB678"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6DB	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB6DB"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6A3	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB6A3"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB662	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB662"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB694	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB694"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB647	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB647"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6CF	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB6CF"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6FA	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB6FA"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6DD	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB6DD"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6CE	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB6CE"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB696	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB696"}
Memory.SKHynix.HMA82GR7CJR8NXN.83ADB631	Memory					{"BusWidthBits":48,"CapacityMiB":15625,"DataWidthBits":40,"ErrorCorrection":"MultiBitECC","Manufacturer":"SK Hynix","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"HMA82GR7CJR8N-XN    ","SerialNumber":"83ADB631"}
Memory.Samsung.M393A2K40DB3CWE.373B9937	Memory					{"BaseModuleType":"RDIMM","BusWidthBits":72,"CapacityMiB":16384,"DataWidthBits":64,"ErrorCorrection":"MultiBitECC","Manufacturer":"Samsung","MemoryType":"DRAM","MemoryDeviceType":"DDR4","OperatingSpeedMhz":3200,"PartNumber":"M393A2K40DB3-CWE","RankCount":1,"SerialNumber":"373B9937"}
\.


--
-- Data for Name: hwinv_by_loc; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.hwinv_by_loc (id, type, ordinal, status, parent, location_info, fru_id, parent_node) FROM stdin;
x3000c0s2e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000TC	x3000c0s2e0
x3000c0s2b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s2b0n0
x3000c0s5b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F306	x3000c0s5b0n0
x3000c0s5b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F295	x3000c0s5b0n0
x3000c0s5b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F25F	x3000c0s5b0n0
x3000c0s8e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000T9	x3000c0s8e0
x3000c0s8e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNAC3	x3000c0s8e0t1
x3000c0s8e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7HS	x3000c0s8e0t0
x3000c0s8b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-s002","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7302P 16-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":128}}	Node.HPE.MXQ03000T9	x3000c0s8b0n0
x3000c0s5b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Samsung.M393A4K40DB3CWE.15B89403	x3000c0s5b0n0
x3000c0s6b0n0d5	Memory	5	Populated		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	FRUIDforx3000c0s6b0n0d5	x3000c0s6b0n0
x3000c0s2b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s2b0n0
x3000c0s17b3n0d3	Memory	3	Populated		{"Id":"12","Name":"Memory 12","Description":"Memory Instance 12","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA77	x3000c0s17b3n0
x3000c0s30e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ14808WM	x3000c0s30e0
x3000c0s30e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"2.03"}	NodeEnclosurePowerSupply.DELTA.5XLNU0H4DF3067	x3000c0s30e0t0
x3000c0s17b3n0d4	Memory	4	Populated		{"Id":"13","Name":"Memory 13","Description":"Memory Instance 13","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD1	x3000c0s17b3n0
x3000c0s17b3n0d5	Memory	5	Populated		{"Id":"14","Name":"Memory 14","Description":"Memory Instance 14","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBACE	x3000c0s17b3n0
x3000c0s6b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F2CC	x3000c0s6b0n0
x3000c0s2b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s2b0n0
x3000c0s6b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F10B	x3000c0s6b0n0
x3000c0s4b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F25B	x3000c0s4b0n0
x3000c0s2b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s2b0n0
x3000c0s17b3n0d6	Memory	6	Populated		{"Id":"15","Name":"Memory 15","Description":"Memory Instance 15","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA33	x3000c0s17b3n0
x3000c0s17b3n0d14	Memory	14	Populated		{"Id":"8","Name":"Memory 8","Description":"Memory Instance 8","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADA	x3000c0s17b3n0
x3000c0s4b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s4b0n0
x3000c0s6b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F108	x3000c0s6b0n0
x3000c0s6b0n0d7	Memory	7	Populated		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	FRUIDforx3000c0s6b0n0d7	x3000c0s6b0n0
x3000c0s2b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s2b0n0
x3000c0s2b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Samsung.M393A2K40DB3CWE.373BAC2E	x3000c0s2b0n0
x3000c0s4b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F263	x3000c0s4b0n0
x3000c0s8b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Samsung.M393A2K40DB3CWE.373B8552	x3000c0s8b0n0
x3000c0s8b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s8b0n0
x3000c0s2b0	NodeBMC	0	Populated		{"DateTime":"2022-08-26T16:35:22Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s2b0	x3000c0s2b0
x3000c0s5b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s5b0n0
x3000c0s5b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F13F	x3000c0s5b0n0
x3000c0s5b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s5b0n0
x3000c0s5b0	NodeBMC	0	Populated		{"DateTime":"2022-08-26T16:35:20Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s5b0	x3000c0s5b0
x3000c0s8b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s8b0n0
x3000c0s8b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Samsung.M393A2K40DB3CWE.373B8991	x3000c0s8b0n0
x3000c0s30b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-w004","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7713P 64-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":256}}	Node.HPE.MXQ14808WM	x3000c0s30b0n0
x3000c0s6e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000TJ	x3000c0s6e0
x3000c0s30b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s30b0n0p0	x3000c0s30b0n0
x3000c0s30b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s30b0n0
x3000c0s30b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Hynix.HMA84GR7DJR4NXN.8580127F	x3000c0s30b0n0
x3000c0s30b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s30b0n0
x3000c0s30b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Hynix.HMA84GR7DJR4NXN.8580117F	x3000c0s30b0n0
x3000c0s6e0t1	NodeEnclosurePowerSupply	1	Empty		{"Name":"HpeServerPowerSupply","FirmwareVersion":"0.00"}	\N	x3000c0s6e0t1
x3000c0s6e0t0	NodeEnclosurePowerSupply	0	Empty		{"Name":"HpeServerPowerSupply","FirmwareVersion":"0.00"}	\N	x3000c0s6e0t0
x3000c0s6b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F141	x3000c0s6b0n0
x3000c0s8b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s8b0n0
x3000c0s30b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Hynix.HMA84GR7DJR4NXN.858011A5	x3000c0s30b0n0
x3000c0s6b0n0d8	Memory	8	Populated		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	FRUIDforx3000c0s6b0n0d8	x3000c0s6b0n0
x3000c0s6b0n0d10	Memory	10	Populated		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	FRUIDforx3000c0s6b0n0d10	x3000c0s6b0n0
x3000c0s6b0n0d1	Memory	1	Populated		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	FRUIDforx3000c0s6b0n0d1	x3000c0s6b0n0
x3000c0s6b0	NodeBMC	0	Populated		{"DateTime":"1970-01-01T00:03:52Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s6b0	x3000c0s6b0
x3000c0s3b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s3b0n0
x3000c0s3b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-m003","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7302P 16-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":128}}	Node.HPE.MXQ03000TD	x3000c0s3b0n0
x3000c0s30b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s30b0n0
x3000c0r15b0	RouterBMC	0	Populated		{"DateTime":"2019-02-14T11:07:32Z","DateTimeLocalOffset":"+00:00","Description":"Shasta Manager","FirmwareVersion":"","Id":"BMC","Name":"BMC"}	FRUIDforx3000c0r15b0	x3000c0r15b0
x3000c0s9b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s9b0n0
x3000c0s5e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000TH	x3000c0s5e0
x3000c0s4b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s4b0n0
x3000c0s4b0	NodeBMC	0	Populated		{"DateTime":"2022-08-26T16:35:20Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s4b0	x3000c0s4b0
x3000c0s3b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s3b0n0p0	x3000c0s3b0n0
x3000c0s9b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Samsung.M393A2K40DB3CWE.373B898F	x3000c0s9b0n0
x3000c0s9b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s9b0n0
x3000c0s6b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s6b0n0p0	x3000c0s6b0n0
x3000c0s9b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Samsung.M393A2K40DB3CWE.373B9A63	x3000c0s9b0n0
x3000c0s9b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s9b0n0
x3000c0s9b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Samsung.M393A2K40DB3CWE.373B86FF	x3000c0s9b0n0
x3000c0s3b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s3b0n0
x3000c0s3b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s3b0n0
x3000c0s3b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s3b0n0
x3000c0s30b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s30b0n0
x3000c0s9b0	NodeBMC	0	Populated		{"DateTime":"2022-08-26T16:35:20Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s9b0	x3000c0s9b0
x3000c0s30b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s30b0n0
x3000c0s30b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Hynix.HMA84GR7DJR4NXN.85801263	x3000c0s30b0n0
x3000c0s30b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Hynix.HMA84GR7DJR4NXN.858011E4	x3000c0s30b0n0
x3000c0s30b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s30b0n0
x3000c0s3b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s3b0n0
x3000c0s30b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s30b0n0
x3000c0s7e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000TB	x3000c0s7e0
x3000c0s7e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7NQ	x3000c0s7e0t0
x3000c0s7b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Samsung.M393A2K40DB3CWE.373B86A3	x3000c0s7b0n0
x3000c0s2e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7AY	x3000c0s2e0t0
x3000c0s2e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7FR	x3000c0s2e0t1
x3000c0s2b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-m002","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7302P 16-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":128}}	Node.HPE.MXQ03000TC	x3000c0s2b0n0
x3000c0s2b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s2b0n0p0	x3000c0s2b0n0
x3000c0s2b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Samsung.M393A2K40DB3CWE.373B9937	x3000c0s2b0n0
x3000c0s2b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Samsung.M393A2K40DB3CWE.373BAB28	x3000c0s2b0n0
x3000c0s7b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Samsung.M393A2K40DB3CWE.373B8939	x3000c0s7b0n0
x3000c0s2b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s2b0n0
x3000c0s7b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Samsung.M393A2K40DB3CWE.373B893A	x3000c0s7b0n0
x3000c0s7b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s7b0n0
x3000c0s7b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Samsung.M393A2K40DB3CWE.373B97AE	x3000c0s7b0n0
x3000c0s3b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s3b0n0
x3000c0s3b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Samsung.M393A2K40DB3CWE.373BABE3	x3000c0s3b0n0
x3000c0s3b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s3b0n0
x3000c0s3b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Samsung.M393A2K40DB3CWE.373B86A8	x3000c0s3b0n0
x3000c0s3b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Samsung.M393A2K40DB3CWE.373B9939	x3000c0s3b0n0
x3000c0s3b0	NodeBMC	0	Populated		{"DateTime":"2022-08-26T16:35:20Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s3b0	x3000c0s3b0
x3000c0s8b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s8b0n0p0	x3000c0s8b0n0
x3000c0s8b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Samsung.M393A2K40DB3CWE.373B993A	x3000c0s8b0n0
x3000c0s8b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s8b0n0
x3000c0s8b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Samsung.M393A2K40DB3CWE.373B8995	x3000c0s8b0n0
x3000c0s8b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s8b0n0
x3000c0s8b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s8b0n0
x3000c0s8b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Samsung.M393A2K40DB3CWE.373B99E1	x3000c0s8b0n0
x3000c0s30b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Hynix.HMA84GR7DJR4NXN.85801261	x3000c0s30b0n0
x3000c0s30b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s30b0n0
x3000c0s8b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Samsung.M393A2K40DB3CWE.373BAAE9	x3000c0s8b0n0
x3000c0s30b0n0h1	NodeHsnNic	1	Populated		{"Id":"DE060000","Name":"NetworkAdapter","Description":""}	FRUIDforx3000c0s30b0n0h1	x3000c0s30b0n0
x3000c0s3b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Samsung.M393A2K40DB3CWE.373BAB2E	x3000c0s3b0n0
x3000c0s30b0n0h2	NodeHsnNic	2	Populated		{"Id":"DE061000","Name":"NetworkAdapter","Description":""}	FRUIDforx3000c0s30b0n0h2	x3000c0s30b0n0
x3000c0s2b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Samsung.M393A2K40DB3CWE.373B9AE1	x3000c0s2b0n0
x3000c0s3b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s3b0n0
x3000c0s2b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Samsung.M393A2K40DB3CWE.373B85D7	x3000c0s2b0n0
x3000c0s7e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDME6K	x3000c0s7e0t1
x3000c0s7b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-s001","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7302P 16-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":128}}	Node.HPE.MXQ03000TB	x3000c0s7b0n0
x3000c0s7b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s7b0n0p0	x3000c0s7b0n0
x3000c0s2b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Samsung.M393A2K40DB3CWE.373B9680	x3000c0s2b0n0
x3000c0s2b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Samsung.M393A2K40DB3CWE.373BABE8	x3000c0s2b0n0
x3000c0s2b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Samsung.M393A2K40DB3CWE.373BABEC	x3000c0s2b0n0
x3000c0s2b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s2b0n0
x3000c0s9e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000T8	x3000c0s9e0
x3000c0s7b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Samsung.M393A2K40DB3CWE.373B893B	x3000c0s7b0n0
x3000c0s3b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Samsung.M393A2K40DB3CWE.373BA7F7	x3000c0s3b0n0
x3000c0s9e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7DN	x3000c0s9e0t0
x3000c0s9e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7HF	x3000c0s9e0t1
x3000c0s7b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s7b0n0
x3000c0s7b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s7b0n0
x3000c0s9b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-s003","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7302P 16-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":128}}	Node.HPE.MXQ03000T8	x3000c0s9b0n0
x3000c0s9b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s9b0n0p0	x3000c0s9b0n0
x3000c0s9b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Samsung.M393A2K40DB3CWE.373B89E3	x3000c0s9b0n0
x3000c0s2b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s2b0n0
x3000c0s4e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000TK	x3000c0s4e0
x3000c0s4e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFQV	x3000c0s4e0t0
x3000c0s4e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNEK6	x3000c0s4e0t1
x3000c0s7b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Samsung.M393A2K40DB3CWE.373B86A7	x3000c0s7b0n0
x3000c0s7b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s7b0n0
x3000c0s7b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s7b0n0
x3000c0s4b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-w001","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7502P 32-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":256}}	Node.HPE.MXQ03000TK	x3000c0s4b0n0
x3000c0s4b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s4b0n0p0	x3000c0s4b0n0
x3000c0s4b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s4b0n0
x3000c0s8b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s8b0n0
x3000c0s8b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Samsung.M393A2K40DB3CWE.373B9940	x3000c0s8b0n0
x3000c0s3b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Samsung.M393A2K40DB3CWE.373B9ADC	x3000c0s3b0n0
x3000c0s3b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Samsung.M393A2K40DB3CWE.373BABE9	x3000c0s3b0n0
x3000c0s3b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Samsung.M393A2K40DB3CWE.373BAB29	x3000c0s3b0n0
x3000c0s30b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Hynix.HMA84GR7DJR4NXN.858011EC	x3000c0s30b0n0
x3000c0s30b0n0g0k0	Drive	0	Populated		{"Id":"DA000003","Name":"Secondary Storage Device","Description":""}	FRUIDforx3000c0s30b0n0g0k0	x3000c0s30b0n0
x3000c0s4b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F2D6	x3000c0s4b0n0
x3000c0s4b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F2E2	x3000c0s4b0n0
x3000c0s4b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s4b0n0
x3000c0s4b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F330	x3000c0s4b0n0
x3000c0s30b0n0h0	NodeHsnNic	0	Populated		{"Id":"DE030000","Name":"Marvell FastLinQ 41000 Series - 2P 25GbE SFP28 QL41232HQCU-HC OCP3 Adapter","Description":""}	NodeHsnNic.AH201041431A.REE2039L34069	x3000c0s30b0n0
x3000c0s17e3	NodeEnclosure	0	Populated		{"Id":"Self","Name":"Computer System Chassis","Description":"Chassis Self","HostName":""}	NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	x3000c0s17e3
x3000c0s17e3t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"nil","FirmwareVersion":""}	FRUIDforx3000c0s17e3t0	x3000c0s17e3t0
x3000c0s17e3t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"nil","FirmwareVersion":""}	FRUIDforx3000c0s17e3t1	x3000c0s17e3t1
x3000c0s17b3	NodeBMC	0	Populated		{"DateTime":"2022-08-29T14:50:01+00:00","DateTimeLocalOffset":"+00:00","Description":"BMC","FirmwareVersion":"12.84.09","Id":"Self","Name":"Manager"}	FRUIDforx3000c0s17b3	x3000c0s17b3
x3000c0s5e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNERP	x3000c0s5e0t0
x3000c0s5e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFPZ	x3000c0s5e0t1
x3000c0s5b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-w002","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7502P 32-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":256}}	Node.HPE.MXQ03000TH	x3000c0s5b0n0
x3000c0s5b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s5b0n0p0	x3000c0s5b0n0
x3000c0s5b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s5b0n0
x3000c0s5b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s5b0n0
x3000c0s9b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Samsung.M393A2K40DB3CWE.373B85DD	x3000c0s9b0n0
x3000c0s9b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Samsung.M393A2K40DB3CWE.373B8990	x3000c0s9b0n0
x3000c0s9b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s9b0n0
x3000c0s9b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s9b0n0
x3000c0s9b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s9b0n0
x3000c0s9b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Samsung.M393A2K40DB3CWE.373BA9FD	x3000c0s9b0n0
x3000c0s9b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s9b0n0
x3000c0s9b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Samsung.M393A2K40DB3CWE.373B8628	x3000c0s9b0n0
x3000c0s9b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s9b0n0
x3000c0s17e2	NodeEnclosure	0	Populated		{"Id":"Self","Name":"Computer System Chassis","Description":"Chassis Self","HostName":""}	NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	x3000c0s17e2
x3000c0s17e2t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"nil","FirmwareVersion":""}	FRUIDforx3000c0s17e2t0	x3000c0s17e2t0
x3000c0s17e2t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"nil","FirmwareVersion":""}	FRUIDforx3000c0s17e2t1	x3000c0s17e2t1
x3000c0s5b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s5b0n0
x3000c0s5b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s5b0n0
x3000c0s5b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F25E	x3000c0s5b0n0
x3000c0s5b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F300	x3000c0s5b0n0
x3000c0s5b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F24F	x3000c0s5b0n0
x3000c0s7b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Samsung.M393A2K40DB3CWE.373B89DD	x3000c0s7b0n0
x3000c0s17b2	NodeBMC	0	Populated		{"DateTime":"2022-08-08T10:10:21+00:00","DateTimeLocalOffset":"+00:00","Description":"BMC","FirmwareVersion":"12.84.09","Id":"Self","Name":"Manager"}	FRUIDforx3000c0s17b2	x3000c0s17b2
x3000c0s17e4	NodeEnclosure	0	Populated		{"Id":"Self","Name":"Computer System Chassis","Description":"Chassis Self","HostName":""}	NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	x3000c0s17e4
x3000c0s17e4t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"nil","FirmwareVersion":""}	FRUIDforx3000c0s17e4t0	x3000c0s17e4t0
x3000c0s17e4t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"nil","FirmwareVersion":""}	FRUIDforx3000c0s17e4t1	x3000c0s17e4t1
x3000c0s17b4n0	Node	0	Populated		{"Id":"Self","Name":"System","Description":"System Self","HostName":"","ProcessorSummary":{"Count":2,"Model":"AMD EPYC 7702 64-Core Processor                "},"MemorySummary":{"TotalSystemMemoryGiB":244}}	Node.CrayInc.102348206.GKG1NC412A006304	x3000c0s17b4n0
x3000c0s17b4n0p0	Processor	0	Populated		{"Id":"1","Name":"Processor 1","Description":"Processor Instance 1","Socket":"P0"}	Processor.AdvancedMicroDevicesInc.2B4AD186862800A	x3000c0s17b4n0
x3000c0s17b4n0p1	Processor	1	Populated		{"Id":"2","Name":"Processor 2","Description":"Processor Instance 2","Socket":"P1"}	Processor.AdvancedMicroDevicesInc.2B4AD186862800B	x3000c0s17b4n0
x3000c0s17b4n0d2	Memory	2	Populated		{"Id":"11","Name":"Memory 11","Description":"Memory Instance 11","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB677	x3000c0s17b4n0
x3000c0s17b4n0d5	Memory	5	Populated		{"Id":"14","Name":"Memory 14","Description":"Memory Instance 14","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6E1	x3000c0s17b4n0
x3000c0s17b4n0d12	Memory	12	Populated		{"Id":"6","Name":"Memory 6","Description":"Memory Instance 6","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB641	x3000c0s17b4n0
x3000c0s7b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s7b0n0
x3000c0s7b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Samsung.M393A2K40DB3CWE.373B97AB	x3000c0s7b0n0
x3000c0s8b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s8b0n0
x3000c0s8b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Samsung.M393A2K40DB3CWE.373B889A	x3000c0s8b0n0
x3000c0s8b0	NodeBMC	0	Populated		{"DateTime":"2022-08-26T16:35:19Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s8b0	x3000c0s8b0
x3000c0s7b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s7b0n0
x3000c0s7b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s7b0n0
x3000c0s5b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s5b0n0
x3000c0s5b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s5b0n0
x3000c0s17b999	NodeBMC	0	Populated		{"DateTime":"2020-09-03T23:08:18+00:00","DateTimeLocalOffset":"+00:00","Description":"BMC","FirmwareVersion":"62.84.02","Id":"Self","Name":"Manager"}	FRUIDforx3000c0s17b999	x3000c0s17b999
x3000c0s17e1	NodeEnclosure	0	Populated		{"Id":"Self","Name":"Computer System Chassis","Description":"Chassis Self","HostName":""}	NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	x3000c0s17e1
x3000c0s17e1t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"nil","FirmwareVersion":""}	FRUIDforx3000c0s17e1t0	x3000c0s17e1t0
x3000c0s17e1t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"nil","FirmwareVersion":""}	FRUIDforx3000c0s17e1t1	x3000c0s17e1t1
x3000c0s17b1n0	Node	0	Populated		{"Id":"Self","Name":"System","Description":"System Self","HostName":"","ProcessorSummary":{"Count":2,"Model":"AMD EPYC 7702 64-Core Processor                "},"MemorySummary":{"TotalSystemMemoryGiB":244}}	Node.CrayInc.102348206.GKG1NC412A006301	x3000c0s17b1n0
x3000c0s17b1n0p0	Processor	0	Populated		{"Id":"1","Name":"Processor 1","Description":"Processor Instance 1","Socket":"P0"}	Processor.AdvancedMicroDevicesInc.2B4AD1868628058	x3000c0s17b1n0
x3000c0s17b1n0p1	Processor	1	Populated		{"Id":"2","Name":"Processor 2","Description":"Processor Instance 2","Socket":"P1"}	Processor.AdvancedMicroDevicesInc.2B4AD186862805A	x3000c0s17b1n0
x3000c0s17b1n0d2	Memory	2	Populated		{"Id":"11","Name":"Memory 11","Description":"Memory Instance 11","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADD	x3000c0s17b1n0
x3000c0s17b1n0d3	Memory	3	Populated		{"Id":"12","Name":"Memory 12","Description":"Memory Instance 12","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADC	x3000c0s17b1n0
x3000c0s17b1n0d11	Memory	11	Populated		{"Id":"5","Name":"Memory 5","Description":"Memory Instance 5","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5C	x3000c0s17b1n0
x3000c0s17b1n0d13	Memory	13	Populated		{"Id":"7","Name":"Memory 7","Description":"Memory Instance 7","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6F	x3000c0s17b1n0
x3000c0s17b1n0d14	Memory	14	Populated		{"Id":"8","Name":"Memory 8","Description":"Memory Instance 8","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAC4	x3000c0s17b1n0
x3000c0s17b1n0d1	Memory	1	Populated		{"Id":"10","Name":"Memory 10","Description":"Memory Instance 10","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBACC	x3000c0s17b1n0
x3000c0s17b1n0d4	Memory	4	Populated		{"Id":"13","Name":"Memory 13","Description":"Memory Instance 13","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA71	x3000c0s17b1n0
x3000c0s17b1n0d5	Memory	5	Populated		{"Id":"14","Name":"Memory 14","Description":"Memory Instance 14","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5F	x3000c0s17b1n0
x3000c0s17b1n0d9	Memory	9	Populated		{"Id":"3","Name":"Memory 3","Description":"Memory Instance 3","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5E	x3000c0s17b1n0
x3000c0s17b1n0d15	Memory	15	Populated		{"Id":"9","Name":"Memory 9","Description":"Memory Instance 9","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD6	x3000c0s17b1n0
x3000c0s17b1n0d0	Memory	0	Populated		{"Id":"1","Name":"Memory 1","Description":"Memory Instance 1","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA60	x3000c0s17b1n0
x3000c0s17b1n0d6	Memory	6	Populated		{"Id":"15","Name":"Memory 15","Description":"Memory Instance 15","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA92	x3000c0s17b1n0
x3000c0s17b1n0d7	Memory	7	Populated		{"Id":"16","Name":"Memory 16","Description":"Memory Instance 16","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5D	x3000c0s17b1n0
x3000c0s17b1n0d8	Memory	8	Populated		{"Id":"2","Name":"Memory 2","Description":"Memory Instance 2","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5B	x3000c0s17b1n0
x3000c0s17b1n0d10	Memory	10	Populated		{"Id":"4","Name":"Memory 4","Description":"Memory Instance 4","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6E	x3000c0s17b1n0
x3000c0s17b1n0d12	Memory	12	Populated		{"Id":"6","Name":"Memory 6","Description":"Memory Instance 6","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6C	x3000c0s17b1n0
x3000c0s17b1	NodeBMC	0	Populated		{"DateTime":"2022-08-08T10:10:33+00:00","DateTimeLocalOffset":"+00:00","Description":"BMC","FirmwareVersion":"12.84.09","Id":"Self","Name":"Manager"}	FRUIDforx3000c0s17b1	x3000c0s17b1
x3000c0s3e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000TD	x3000c0s3e0
x3000c0s30e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"2.03"}	NodeEnclosurePowerSupply.DELTA.5XLNU0H4DF303Y	x3000c0s30e0t1
x3000c0s6b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"ncn-w003","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7502P 32-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":256}}	Node.HPE.MXQ03000TJ	x3000c0s6b0n0
x3000c0s17b4n0d15	Memory	15	Populated		{"Id":"9","Name":"Memory 9","Description":"Memory Instance 9","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB655	x3000c0s17b4n0
x3000c0s17b4n0d6	Memory	6	Populated		{"Id":"15","Name":"Memory 15","Description":"Memory Instance 15","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB62D	x3000c0s17b4n0
x3000c0s17b4n0d8	Memory	8	Populated		{"Id":"2","Name":"Memory 2","Description":"Memory Instance 2","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA76	x3000c0s17b4n0
x3000c0s17b4n0d10	Memory	10	Populated		{"Id":"4","Name":"Memory 4","Description":"Memory Instance 4","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA91	x3000c0s17b4n0
x3000c0s17b4n0d0	Memory	0	Populated		{"Id":"1","Name":"Memory 1","Description":"Memory Instance 1","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA73	x3000c0s17b4n0
x3000c0s17b4n0d3	Memory	3	Populated		{"Id":"12","Name":"Memory 12","Description":"Memory Instance 12","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB653	x3000c0s17b4n0
x3000c0s17b4n0d7	Memory	7	Populated		{"Id":"16","Name":"Memory 16","Description":"Memory Instance 16","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB62E	x3000c0s17b4n0
x3000c0s17b4n0d9	Memory	9	Populated		{"Id":"3","Name":"Memory 3","Description":"Memory Instance 3","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA74	x3000c0s17b4n0
x3000c0s17b4n0d11	Memory	11	Populated		{"Id":"5","Name":"Memory 5","Description":"Memory Instance 5","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB759	x3000c0s17b4n0
x3000c0s17b4n0d1	Memory	1	Populated		{"Id":"10","Name":"Memory 10","Description":"Memory Instance 10","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB682	x3000c0s17b4n0
x3000c0s17b4n0d4	Memory	4	Populated		{"Id":"13","Name":"Memory 13","Description":"Memory Instance 13","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB69C	x3000c0s17b4n0
x3000c0s17b4n0d13	Memory	13	Populated		{"Id":"7","Name":"Memory 7","Description":"Memory Instance 7","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB698	x3000c0s17b4n0
x3000c0s17b4n0d14	Memory	14	Populated		{"Id":"8","Name":"Memory 8","Description":"Memory Instance 8","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB695	x3000c0s17b4n0
x3000c0s17b4	NodeBMC	0	Populated		{"DateTime":"2022-08-08T10:10:21+00:00","DateTimeLocalOffset":"+00:00","Description":"BMC","FirmwareVersion":"12.84.09","Id":"Self","Name":"Manager"}	FRUIDforx3000c0s17b4	x3000c0s17b4
x3000c0s19e0	NodeEnclosure	0	Populated		{"Id":"1","Name":"Computer System Chassis","Description":"","HostName":""}	NodeEnclosure.HPE.MXQ03000TG	x3000c0s19e0
x3000c0s19e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNAER	x3000c0s19e0t0
x3000c0s19e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFPR	x3000c0s19e0t1
x3000c0s19b0n0	Node	0	Populated		{"Id":"1","Name":"Computer System","Description":"","HostName":"","ProcessorSummary":{"Count":1,"Model":"AMD EPYC 7502P 32-Core Processor               "},"MemorySummary":{"TotalSystemMemoryGiB":256}}	Node.HPE.MXQ03000TG	x3000c0s19b0n0
x3000c0s19b0n0p0	Processor	0	Populated		{"Id":"1","Name":"Processors","Description":"","Socket":"Proc 1"}	FRUIDforx3000c0s19b0n0p0	x3000c0s19b0n0
x3000c0s19b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s19b0n0
x3000c0s19b0n0d4	Memory	4	Populated		{"Id":"proc1dimm5","Name":"proc1dimm5","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":5}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F347	x3000c0s19b0n0
x3000c0s19b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F266	x3000c0s19b0n0
x3000c0s19b0n0d15	Memory	15	Populated		{"Id":"proc1dimm16","Name":"proc1dimm16","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":16}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F349	x3000c0s19b0n0
x3000c0s19b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s19b0n0
x3000c0s19b0n0d8	Memory	8	Empty		{"Id":"proc1dimm9","Name":"proc1dimm9","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":9}}	\N	x3000c0s19b0n0
x3000c0s19b0n0d10	Memory	10	Empty		{"Id":"proc1dimm11","Name":"proc1dimm11","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":11}}	\N	x3000c0s19b0n0
x3000c0s19b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F269	x3000c0s19b0n0
x3000c0s19b0n0d13	Memory	13	Populated		{"Id":"proc1dimm14","Name":"proc1dimm14","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":14}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F256	x3000c0s19b0n0
x3000c0s19b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F30B	x3000c0s19b0n0
x3000c0s19b0n0d7	Memory	7	Empty		{"Id":"proc1dimm8","Name":"proc1dimm8","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":8}}	\N	x3000c0s19b0n0
x3000c0s19b0n0d12	Memory	12	Empty		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	\N	x3000c0s19b0n0
x3000c0s19b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F167	x3000c0s19b0n0
x3000c0s19b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s19b0n0
x3000c0s19b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F348	x3000c0s19b0n0
x3000c0s19b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s19b0n0
x3000c0s19b0	NodeBMC	0	Populated		{"DateTime":"2022-08-08T10:10:09Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.14","Id":"1","Name":"Manager"}	FRUIDforx3000c0s19b0	x3000c0s19b0
x3000c0s3e0t0	NodeEnclosurePowerSupply	0	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7K4	x3000c0s3e0t0
x3000c0s3e0t1	NodeEnclosurePowerSupply	1	Populated		{"Name":"HpeServerPowerSupply","FirmwareVersion":"1.00"}	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFRM	x3000c0s3e0t1
x3000c0r15e0	HSNBoard	0	Populated		{"Id":"Enclosure","Name":"Enclosure","Description":"101878104","HostName":""}	FRUIDforx3000c0r15e0	x3000c0r15e0
x3000c0s17b3n0	Node	0	Populated		{"Id":"Self","Name":"System","Description":"System Self","HostName":"","ProcessorSummary":{"Count":2,"Model":"AMD EPYC 7702 64-Core Processor                "},"MemorySummary":{"TotalSystemMemoryGiB":244}}	Node.CrayInc.102348206.GKG1NC412A006303	x3000c0s17b3n0
x3000c0s30b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Hynix.HMA84GR7DJR4NXN.8580127C	x3000c0s30b0n0
x3000c0s17b3n0p0	Processor	0	Populated		{"Id":"1","Name":"Processor 1","Description":"Processor Instance 1","Socket":"P0"}	Processor.AdvancedMicroDevicesInc.2B4AD1868628054	x3000c0s17b3n0
x3000c0s17b3n0p1	Processor	1	Populated		{"Id":"2","Name":"Processor 2","Description":"Processor Instance 2","Socket":"P1"}	Processor.AdvancedMicroDevicesInc.2B4AD1868628055	x3000c0s17b3n0
x3000c0s30b0	NodeBMC	0	Populated		{"DateTime":"2022-08-26T16:35:19Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s30b0	x3000c0s30b0
x3000c0s17b3n0d13	Memory	13	Populated		{"Id":"7","Name":"Memory 7","Description":"Memory Instance 7","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA98	x3000c0s17b3n0
x3000c0s17b3n0d1	Memory	1	Populated		{"Id":"10","Name":"Memory 10","Description":"Memory Instance 10","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD9	x3000c0s17b3n0
x3000c0s17b3n0d8	Memory	8	Populated		{"Id":"2","Name":"Memory 2","Description":"Memory Instance 2","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAE1	x3000c0s17b3n0
x3000c0s17b3n0d9	Memory	9	Populated		{"Id":"3","Name":"Memory 3","Description":"Memory Instance 3","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADF	x3000c0s17b3n0
x3000c0s4b0n0d3	Memory	3	Empty		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	\N	x3000c0s4b0n0
x3000c0s7b0	NodeBMC	0	Populated		{"DateTime":"2022-08-26T16:35:22Z","DateTimeLocalOffset":"+00:00","Description":"","FirmwareVersion":"iLO 5 v2.44","Id":"1","Name":"Manager"}	FRUIDforx3000c0s7b0	x3000c0s7b0
x3000c0s6b0n0d14	Memory	14	Populated		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	FRUIDforx3000c0s6b0n0d14	x3000c0s6b0n0
x3000c0s6b0n0d3	Memory	3	Populated		{"Id":"proc1dimm4","Name":"proc1dimm4","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":4}}	FRUIDforx3000c0s6b0n0d3	x3000c0s6b0n0
x3000c0s6b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F2CF	x3000c0s6b0n0
x3000c0s6b0n0d12	Memory	12	Populated		{"Id":"proc1dimm13","Name":"proc1dimm13","Description":"","MemoryLocation":{"Socket":1,"MemoryController":6,"Channel":6,"Slot":13}}	FRUIDforx3000c0s6b0n0d12	x3000c0s6b0n0
x3000c0s4b0n0d9	Memory	9	Populated		{"Id":"proc1dimm10","Name":"proc1dimm10","Description":"","MemoryLocation":{"Socket":1,"MemoryController":7,"Channel":7,"Slot":10}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F346	x3000c0s4b0n0
x3000c0s4b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F26F	x3000c0s4b0n0
x3000c0s4b0n0d1	Memory	1	Empty		{"Id":"proc1dimm2","Name":"proc1dimm2","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":2}}	\N	x3000c0s4b0n0
x3000c0s4b0n0d5	Memory	5	Empty		{"Id":"proc1dimm6","Name":"proc1dimm6","Description":"","MemoryLocation":{"Socket":1,"MemoryController":2,"Channel":2,"Slot":6}}	\N	x3000c0s4b0n0
x3000c0s17b3n0d2	Memory	2	Populated		{"Id":"11","Name":"Memory 11","Description":"Memory Instance 11","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAAE	x3000c0s17b3n0
x3000c0s17b3n0d12	Memory	12	Populated		{"Id":"6","Name":"Memory 6","Description":"Memory Instance 6","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA75	x3000c0s17b3n0
x3000c0s17b3n0d7	Memory	7	Populated		{"Id":"16","Name":"Memory 16","Description":"Memory Instance 16","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA3E	x3000c0s17b3n0
x3000c0s17b3n0d10	Memory	10	Populated		{"Id":"4","Name":"Memory 4","Description":"Memory Instance 4","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAB3	x3000c0s17b3n0
x3000c0s17b3n0d11	Memory	11	Populated		{"Id":"5","Name":"Memory 5","Description":"Memory Instance 5","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA9A	x3000c0s17b3n0
x3000c0s17b3n0d15	Memory	15	Populated		{"Id":"9","Name":"Memory 9","Description":"Memory Instance 9","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAAC	x3000c0s17b3n0
x3000c0s17b3n0d0	Memory	0	Populated		{"Id":"1","Name":"Memory 1","Description":"Memory Instance 1","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAE0	x3000c0s17b3n0
x3000c0s4b0n0d6	Memory	6	Populated		{"Id":"proc1dimm7","Name":"proc1dimm7","Description":"","MemoryLocation":{"Socket":1,"MemoryController":1,"Channel":1,"Slot":7}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F32F	x3000c0s4b0n0
x3000c0s4b0n0d14	Memory	14	Empty		{"Id":"proc1dimm15","Name":"proc1dimm15","Description":"","MemoryLocation":{"Socket":1,"MemoryController":5,"Channel":5,"Slot":15}}	\N	x3000c0s4b0n0
x3000c0s17b2n0	Node	0	Populated		{"Id":"Self","Name":"System","Description":"System Self","HostName":"","ProcessorSummary":{"Count":2,"Model":"AMD EPYC 7702 64-Core Processor                "},"MemorySummary":{"TotalSystemMemoryGiB":244}}	Node.CrayInc.102348206.GKG1NC412A006302	x3000c0s17b2n0
x3000c0s6b0n0d0	Memory	0	Populated		{"Id":"proc1dimm1","Name":"proc1dimm1","Description":"","MemoryLocation":{"Socket":1,"MemoryController":3,"Channel":3,"Slot":1}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F0F3	x3000c0s6b0n0
x3000c0s6b0n0d11	Memory	11	Populated		{"Id":"proc1dimm12","Name":"proc1dimm12","Description":"","MemoryLocation":{"Socket":1,"MemoryController":8,"Channel":8,"Slot":12}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F140	x3000c0s6b0n0
x3000c0s6b0n0d2	Memory	2	Populated		{"Id":"proc1dimm3","Name":"proc1dimm3","Description":"","MemoryLocation":{"Socket":1,"MemoryController":4,"Channel":4,"Slot":3}}	Memory.Hynix.HMA84GR7CJR4NXN.3444F16D	x3000c0s6b0n0
x3000c0s17b2n0p0	Processor	0	Populated		{"Id":"1","Name":"Processor 1","Description":"Processor Instance 1","Socket":"P0"}	Processor.AdvancedMicroDevicesInc.2B4AD1868628009	x3000c0s17b2n0
x3000c0s17b2n0p1	Processor	1	Populated		{"Id":"2","Name":"Processor 2","Description":"Processor Instance 2","Socket":"P1"}	Processor.AdvancedMicroDevicesInc.2B4AD186862800E	x3000c0s17b2n0
x3000c0s17b2n0d9	Memory	9	Populated		{"Id":"3","Name":"Memory 3","Description":"Memory Instance 3","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB633	x3000c0s17b2n0
x3000c0s17b2n0d13	Memory	13	Populated		{"Id":"7","Name":"Memory 7","Description":"Memory Instance 7","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB678	x3000c0s17b2n0
x3000c0s17b2n0d11	Memory	11	Populated		{"Id":"5","Name":"Memory 5","Description":"Memory Instance 5","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6DB	x3000c0s17b2n0
x3000c0s17b2n0d6	Memory	6	Populated		{"Id":"15","Name":"Memory 15","Description":"Memory Instance 15","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6A3	x3000c0s17b2n0
x3000c0s17b2n0d7	Memory	7	Populated		{"Id":"16","Name":"Memory 16","Description":"Memory Instance 16","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB654	x3000c0s17b2n0
x3000c0s17b2n0d1	Memory	1	Populated		{"Id":"10","Name":"Memory 10","Description":"Memory Instance 10","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6FA	x3000c0s17b2n0
x3000c0s17b2n0d4	Memory	4	Populated		{"Id":"13","Name":"Memory 13","Description":"Memory Instance 13","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6A5	x3000c0s17b2n0
x3000c0s17b2n0d14	Memory	14	Populated		{"Id":"8","Name":"Memory 8","Description":"Memory Instance 8","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB640	x3000c0s17b2n0
x3000c0s17b2n0d0	Memory	0	Populated		{"Id":"1","Name":"Memory 1","Description":"Memory Instance 1","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB696	x3000c0s17b2n0
x3000c0s17b2n0d10	Memory	10	Populated		{"Id":"4","Name":"Memory 4","Description":"Memory Instance 4","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB631	x3000c0s17b2n0
x3000c0s17b2n0d5	Memory	5	Populated		{"Id":"14","Name":"Memory 14","Description":"Memory Instance 14","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB662	x3000c0s17b2n0
x3000c0s17b2n0d8	Memory	8	Populated		{"Id":"2","Name":"Memory 2","Description":"Memory Instance 2","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB694	x3000c0s17b2n0
x3000c0s17b2n0d12	Memory	12	Populated		{"Id":"6","Name":"Memory 6","Description":"Memory Instance 6","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB647	x3000c0s17b2n0
x3000c0s17b2n0d15	Memory	15	Populated		{"Id":"9","Name":"Memory 9","Description":"Memory Instance 9","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6CF	x3000c0s17b2n0
x3000c0s17b2n0d2	Memory	2	Populated		{"Id":"11","Name":"Memory 11","Description":"Memory Instance 11","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6DD	x3000c0s17b2n0
x3000c0s17b2n0d3	Memory	3	Populated		{"Id":"12","Name":"Memory 12","Description":"Memory Instance 12","MemoryLocation":{"Socket":0,"MemoryController":0,"Channel":0,"Slot":0}}	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6CE	x3000c0s17b2n0
\.


--
-- Data for Name: hwinv_hist; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.hwinv_hist (id, fru_id, event_type, "timestamp") FROM stdin;
x3000c0s2e0	NodeEnclosure.HPE.MXQ03000TC	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7FR	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7AY	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0	Node.HPE.MXQ03000TC	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0p0	FRUIDforx3000c0s2b0n0p0	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0d2	Memory.Samsung.M393A2K40DB3CWE.373B9AE1	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0d4	Memory.Samsung.M393A2K40DB3CWE.373BAB28	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0d15	Memory.Samsung.M393A2K40DB3CWE.373B9680	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0d0	Memory.Samsung.M393A2K40DB3CWE.373BABE8	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0d6	Memory.Samsung.M393A2K40DB3CWE.373B9937	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0d11	Memory.Samsung.M393A2K40DB3CWE.373B85D7	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0d13	Memory.Samsung.M393A2K40DB3CWE.373BAC2E	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0n0d9	Memory.Samsung.M393A2K40DB3CWE.373BABEC	Detected	2022-08-08 09:04:01.3761+00
x3000c0s2b0	FRUIDforx3000c0s2b0	Detected	2022-08-08 09:04:01.3761+00
x3000c0s8e0	NodeEnclosure.HPE.MXQ03000T9	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7HS	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNAC3	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0	Node.HPE.MXQ03000T9	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0p0	FRUIDforx3000c0s8b0n0p0	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0d0	Memory.Samsung.M393A2K40DB3CWE.373B993A	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0d6	Memory.Samsung.M393A2K40DB3CWE.373B9940	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0d13	Memory.Samsung.M393A2K40DB3CWE.373B8995	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0d9	Memory.Samsung.M393A2K40DB3CWE.373B99E1	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0d15	Memory.Samsung.M393A2K40DB3CWE.373BAAE9	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0d2	Memory.Samsung.M393A2K40DB3CWE.373B889A	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0d4	Memory.Samsung.M393A2K40DB3CWE.373B8991	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0n0d11	Memory.Samsung.M393A2K40DB3CWE.373B8552	Detected	2022-08-08 09:04:01.996479+00
x3000c0s8b0	FRUIDforx3000c0s8b0	Detected	2022-08-08 09:04:01.996479+00
x3000c0s9e0	NodeEnclosure.HPE.MXQ03000T8	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7DN	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7HF	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0	Node.HPE.MXQ03000T8	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0p0	FRUIDforx3000c0s9b0n0p0	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0d9	Memory.Samsung.M393A2K40DB3CWE.373B9A63	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0d13	Memory.Samsung.M393A2K40DB3CWE.373B898F	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0d15	Memory.Samsung.M393A2K40DB3CWE.373B86FF	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0d4	Memory.Samsung.M393A2K40DB3CWE.373B8990	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0d11	Memory.Samsung.M393A2K40DB3CWE.373B85DD	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0d2	Memory.Samsung.M393A2K40DB3CWE.373BA9FD	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0d0	Memory.Samsung.M393A2K40DB3CWE.373B89E3	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0n0d6	Memory.Samsung.M393A2K40DB3CWE.373B8628	Detected	2022-08-08 09:04:02.308615+00
x3000c0s9b0	FRUIDforx3000c0s9b0	Detected	2022-08-08 09:04:02.308615+00
x3000c0s6e0	NodeEnclosure.HPE.MXQ03000TJ	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFPE	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDMF3J	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0	Node.HPE.MXQ03000TJ	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0p0	FRUIDforx3000c0s6b0n0p0	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0d2	Memory.Hynix.HMA84GR7CJR4NXN.3444F16D	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0d4	Memory.Hynix.HMA84GR7CJR4NXN.3444F2CC	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0d9	Memory.Hynix.HMA84GR7CJR4NXN.3444F141	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0d13	Memory.Hynix.HMA84GR7CJR4NXN.3444F10B	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0d0	Memory.Hynix.HMA84GR7CJR4NXN.3444F0F3	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0d11	Memory.Hynix.HMA84GR7CJR4NXN.3444F140	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0d15	Memory.Hynix.HMA84GR7CJR4NXN.3444F108	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0n0d6	Memory.Hynix.HMA84GR7CJR4NXN.3444F2CF	Detected	2022-08-08 09:04:03.107462+00
x3000c0s6b0	FRUIDforx3000c0s6b0	Detected	2022-08-08 09:04:03.107462+00
x3000c0s5e0	NodeEnclosure.HPE.MXQ03000TH	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNERP	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFPZ	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0	Node.HPE.MXQ03000TH	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0p0	FRUIDforx3000c0s5b0n0p0	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0d0	Memory.Hynix.HMA84GR7CJR4NXN.3444F25E	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0d6	Memory.Hynix.HMA84GR7CJR4NXN.3444F300	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0d11	Memory.Hynix.HMA84GR7CJR4NXN.3444F306	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0d9	Memory.Hynix.HMA84GR7CJR4NXN.3444F24F	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0d13	Memory.Hynix.HMA84GR7CJR4NXN.3444F295	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0d15	Memory.Hynix.HMA84GR7CJR4NXN.3444F13F	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0d4	Memory.Samsung.M393A4K40DB3CWE.15B89403	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0n0d2	Memory.Hynix.HMA84GR7CJR4NXN.3444F25F	Detected	2022-08-08 09:04:03.176793+00
x3000c0s5b0	FRUIDforx3000c0s5b0	Detected	2022-08-08 09:04:03.176793+00
x3000c0s7e0	NodeEnclosure.HPE.MXQ03000TB	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDM7NQ	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDME6K	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0	Node.HPE.MXQ03000TB	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0p0	FRUIDforx3000c0s7b0n0p0	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0d9	Memory.Samsung.M393A2K40DB3CWE.373B893A	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0d0	Memory.Samsung.M393A2K40DB3CWE.373B893B	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0d2	Memory.Samsung.M393A2K40DB3CWE.373B86A3	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0d4	Memory.Samsung.M393A2K40DB3CWE.373B8939	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0d6	Memory.Samsung.M393A2K40DB3CWE.373B97AE	Detected	2022-08-08 09:04:03.894815+00
x3000c0s4e0	NodeEnclosure.HPE.MXQ03000TK	Detected	2022-08-08 09:04:04.60814+00
x3000c0s7b0n0d13	Memory.Samsung.M393A2K40DB3CWE.373B89DD	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0d11	Memory.Samsung.M393A2K40DB3CWE.373B86A7	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0n0d15	Memory.Samsung.M393A2K40DB3CWE.373B97AB	Detected	2022-08-08 09:04:03.894815+00
x3000c0s7b0	FRUIDforx3000c0s7b0	Detected	2022-08-08 09:04:03.894815+00
x3000c0s4e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFQV	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNEK6	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0	Node.HPE.MXQ03000TK	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0p0	FRUIDforx3000c0s4b0n0p0	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0d15	Memory.Hynix.HMA84GR7CJR4NXN.3444F263	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0d4	Memory.Hynix.HMA84GR7CJR4NXN.3444F25B	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0d13	Memory.Hynix.HMA84GR7CJR4NXN.3444F2D6	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0d9	Memory.Hynix.HMA84GR7CJR4NXN.3444F346	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0d6	Memory.Hynix.HMA84GR7CJR4NXN.3444F32F	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0d11	Memory.Hynix.HMA84GR7CJR4NXN.3444F330	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0d0	Memory.Hynix.HMA84GR7CJR4NXN.3444F26F	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0n0d2	Memory.Hynix.HMA84GR7CJR4NXN.3444F2E2	Detected	2022-08-08 09:04:04.60814+00
x3000c0s4b0	FRUIDforx3000c0s4b0	Detected	2022-08-08 09:04:04.60814+00
x3000c0s3e0	NodeEnclosure.HPE.MXQ03000TD	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDN7K4	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFRM	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0	Node.HPE.MXQ03000TD	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0p0	FRUIDforx3000c0s3b0n0p0	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0d2	Memory.Samsung.M393A2K40DB3CWE.373B86A8	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0d0	Memory.Samsung.M393A2K40DB3CWE.373BAB29	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0d4	Memory.Samsung.M393A2K40DB3CWE.373BABE3	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0d9	Memory.Samsung.M393A2K40DB3CWE.373BABE9	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0d11	Memory.Samsung.M393A2K40DB3CWE.373BA7F7	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0d6	Memory.Samsung.M393A2K40DB3CWE.373B9ADC	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0d13	Memory.Samsung.M393A2K40DB3CWE.373BAB2E	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0n0d15	Memory.Samsung.M393A2K40DB3CWE.373B9939	Detected	2022-08-08 09:04:04.990701+00
x3000c0s3b0	FRUIDforx3000c0s3b0	Detected	2022-08-08 09:04:04.990701+00
x3000c0s17e3	NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17e3t1	FRUIDforx3000c0s17e3t1	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17e3t0	FRUIDforx3000c0s17e3t0	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0	Node.CrayInc.102348206.GKG1NC412A006303	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0p0	Processor.AdvancedMicroDevicesInc.2B4AD1868628054	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0p1	Processor.AdvancedMicroDevicesInc.2B4AD1868628055	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d3	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA77	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d5	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBACE	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d11	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA9A	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d12	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA75	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d6	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA33	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d7	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA3E	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d9	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADF	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d0	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAE0	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d8	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAE1	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d14	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADA	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d15	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAAC	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d1	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD9	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d2	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAAE	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d4	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD1	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d10	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAB3	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3n0d13	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA98	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17b3	FRUIDforx3000c0s17b3	Detected	2022-08-08 10:10:53.98283+00
x3000c0s17e2	NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17e2t0	FRUIDforx3000c0s17e2t0	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17e2t1	FRUIDforx3000c0s17e2t1	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0	Node.CrayInc.102348206.GKG1NC412A006302	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0p0	Processor.AdvancedMicroDevicesInc.2B4AD1868628009	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0p1	Processor.AdvancedMicroDevicesInc.2B4AD186862800E	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d1	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6FA	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d6	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6A3	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d0	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB696	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d9	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB633	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d14	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB640	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d15	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6CF	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d7	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB654	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d8	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB694	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d13	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB678	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d12	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB647	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d2	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6DD	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d3	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6CE	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d4	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6A5	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d5	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB662	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d10	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB631	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2n0d11	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6DB	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b2	FRUIDforx3000c0s17b2	Detected	2022-08-08 10:10:57.627402+00
x3000c0s17b999	FRUIDforx3000c0s17b999	Detected	2022-08-08 10:11:10.249811+00
x3000c0s17e4	NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17e4t0	FRUIDforx3000c0s17e4t0	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17e4t1	FRUIDforx3000c0s17e4t1	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0	Node.CrayInc.102348206.GKG1NC412A006304	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0p0	Processor.AdvancedMicroDevicesInc.2B4AD186862800A	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0p1	Processor.AdvancedMicroDevicesInc.2B4AD186862800B	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d2	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB677	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d5	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB6E1	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d12	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB641	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d15	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB655	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d6	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB62D	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d8	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA76	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d10	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA91	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d0	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA73	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d3	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB653	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d7	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB62E	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d9	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA74	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d11	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB759	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d1	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB682	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d4	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB69C	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d13	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB698	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4n0d14	Memory.SKHynix.HMA82GR7CJR8NXN.83ADB695	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17b4	FRUIDforx3000c0s17b4	Detected	2022-08-08 10:11:11.44831+00
x3000c0s17e1	NodeEnclosure.CrayInc.6NH262Z63MRYF100.GKG1NC412A0063	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17e1t0	FRUIDforx3000c0s17e1t0	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17e1t1	FRUIDforx3000c0s17e1t1	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0	Node.CrayInc.102348206.GKG1NC412A006301	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0p0	Processor.AdvancedMicroDevicesInc.2B4AD1868628058	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0p1	Processor.AdvancedMicroDevicesInc.2B4AD186862805A	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d2	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADD	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d3	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBADC	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d11	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5C	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d13	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6F	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d14	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAC4	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d1	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBACC	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d4	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA71	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d5	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5F	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d9	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5E	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d15	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBAD6	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d0	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA60	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d6	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA92	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d7	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5D	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d8	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA5B	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d10	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6E	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1n0d12	Memory.SKHynix.HMA82GR7CJR8NXN.83ADBA6C	Detected	2022-08-08 10:11:13.620179+00
x3000c0s17b1	FRUIDforx3000c0s17b1	Detected	2022-08-08 10:11:13.620179+00
x3000c0s19e0	NodeEnclosure.HPE.MXQ03000TG	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19e0t0	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNAER	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19e0t1	NodeEnclosurePowerSupply.LTEON.5WBXK0FLLDNFPR	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0	Node.HPE.MXQ03000TG	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0p0	FRUIDforx3000c0s19b0n0p0	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0d4	Memory.Hynix.HMA84GR7CJR4NXN.3444F347	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0d9	Memory.Hynix.HMA84GR7CJR4NXN.3444F266	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0d15	Memory.Hynix.HMA84GR7CJR4NXN.3444F349	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0d11	Memory.Hynix.HMA84GR7CJR4NXN.3444F269	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0d13	Memory.Hynix.HMA84GR7CJR4NXN.3444F256	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0d0	Memory.Hynix.HMA84GR7CJR4NXN.3444F30B	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0d2	Memory.Hynix.HMA84GR7CJR4NXN.3444F167	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0n0d6	Memory.Hynix.HMA84GR7CJR4NXN.3444F348	Detected	2022-08-08 10:11:26.905718+00
x3000c0s19b0	FRUIDforx3000c0s19b0	Detected	2022-08-08 10:11:26.905718+00
x3000c0r15e0	FRUIDforx3000c0r15e0	Detected	2022-08-08 10:13:20.618691+00
x3000c0r15b0	FRUIDforx3000c0r15b0	Detected	2022-08-08 10:13:20.618691+00
x3000c0s30e0	NodeEnclosure.HPE.MXQ14808WM	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30e0t0	NodeEnclosurePowerSupply.DELTA.5XLNU0H4DF3067	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30e0t1	NodeEnclosurePowerSupply.DELTA.5XLNU0H4DF303Y	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0	Node.HPE.MXQ14808WM	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0p0	FRUIDforx3000c0s30b0n0p0	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0d2	Memory.Hynix.HMA84GR7DJR4NXN.858011A5	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0d6	Memory.Hynix.HMA84GR7DJR4NXN.8580127C	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0d9	Memory.Hynix.HMA84GR7DJR4NXN.858011EC	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0d4	Memory.Hynix.HMA84GR7DJR4NXN.8580127F	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0d13	Memory.Hynix.HMA84GR7DJR4NXN.85801261	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0d15	Memory.Hynix.HMA84GR7DJR4NXN.8580117F	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0d0	Memory.Hynix.HMA84GR7DJR4NXN.85801263	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0d11	Memory.Hynix.HMA84GR7DJR4NXN.858011E4	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0g0k0	FRUIDforx3000c0s30b0n0g0k0	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0h0	NodeHsnNic.AH201041431A.REE2039L34069	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0h1	FRUIDforx3000c0s30b0n0h1	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0n0h2	FRUIDforx3000c0s30b0n0h2	Detected	2022-08-18 22:19:34.28631+00
x3000c0s30b0	FRUIDforx3000c0s30b0	Detected	2022-08-18 22:19:34.28631+00
x3000c0s6b0n0d14	FRUIDforx3000c0s6b0n0d14	Detected	2022-08-26 16:54:57.669752+00
x3000c0s6b0n0d3	FRUIDforx3000c0s6b0n0d3	Detected	2022-08-26 16:54:57.669752+00
x3000c0s6b0n0d8	FRUIDforx3000c0s6b0n0d8	Detected	2022-08-26 16:54:57.669752+00
x3000c0s6b0n0d10	FRUIDforx3000c0s6b0n0d10	Detected	2022-08-26 16:54:57.669752+00
x3000c0s6b0n0d1	FRUIDforx3000c0s6b0n0d1	Detected	2022-08-26 16:54:57.669752+00
x3000c0s6b0n0d12	FRUIDforx3000c0s6b0n0d12	Detected	2022-08-26 16:54:57.669752+00
x3000c0s6b0n0d5	FRUIDforx3000c0s6b0n0d5	Detected	2022-08-26 16:54:57.669752+00
x3000c0s6b0n0d7	FRUIDforx3000c0s6b0n0d7	Detected	2022-08-26 16:54:57.669752+00
\.


--
-- Data for Name: job_state_rf_poll; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.job_state_rf_poll (comp_id, job_id) FROM stdin;
x3000c0s30b0n0	02e2f1fd-b3dd-4b11-a7f9-efe1672092c7
\.


--
-- Data for Name: job_sync; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.job_sync (id, type, status, last_update, lifetime) FROM stdin;
02e2f1fd-b3dd-4b11-a7f9-efe1672092c7	StateRFPoll	InProgress	2022-09-02 19:43:40.207701+00	30
\.


--
-- Data for Name: node_nid_mapping; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.node_nid_mapping (id, nid, role, name, node_info, subrole) FROM stdin;
\.


--
-- Data for Name: power_mapping; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.power_mapping (id, powered_by) FROM stdin;
\.


--
-- Data for Name: reservations; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.reservations (component_id, create_timestamp, expiration_timestamp, deputy_key, reservation_key) FROM stdin;
\.


--
-- Data for Name: rf_endpoints; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.rf_endpoints (id, type, name, hostname, domain, fqdn, ip_info, enabled, uuid, "user", password, usessdp, macrequired, macaddr, rediscoveronupdate, templateid, discovery_info, ipaddr) FROM stdin;
x3000c0s5b0	NodeBMC				x3000c0s5b0	{}	t	b7384d1d-08ea-52f7-8a1d-f343b13559ea	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:35:36.298226Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000c0r15b0	RouterBMC		x3000c0r15b0		x3000c0r15b0	{}	t		root		f	f	0040a6831b53	t		{"LastDiscoveryAttempt":"2022-08-25T10:48:59.134598Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.2.0"}	
x3000c0s9b0	NodeBMC				x3000c0s9b0	{}	t	bf80c480-3b3e-52af-b56b-302071a8ba4c	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:35:36.930444Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000c0s8b0	NodeBMC				x3000c0s8b0	{}	t	de90dab4-8270-5698-a6f6-31a6315fae69	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:35:37.965594Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000c0s3b0	NodeBMC				x3000c0s3b0	{}	t	e9eeba67-a5bd-5795-8a1e-9355d67dc255	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:35:38.196100Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000c0s1b0	NodeBMC				x3000c0s1b0	{}	t		root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:36:10.979554Z","LastDiscoveryStatus":"HTTPsGetFailed"}	
x3000c0s17b3	NodeBMC		x3000c0s17b3		x3000c0s17b3	{}	t	40f2306f-debf-0010-e903-b42e99dfebc1	root		f	f	b42e99dfebc1	t		{"LastDiscoveryAttempt":"2022-08-29T14:50:40.265307Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.7.0"}	
x3000c0s17b2	NodeBMC		x3000c0s17b2		x3000c0s17b2	{}	t	40f2306f-debf-0010-e903-b42e99dfecf1	root		f	f	b42e99dfecf1	t		{"LastDiscoveryAttempt":"2022-08-08T10:10:57.479940Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.7.0"}	
x3000c0s17b999	NodeBMC		x3000c0s17b999		x3000c0s17b999	{}	t	009ea76e-debf-0010-ef03-b42e99bdd255	root		f	f	b42e99bdd255	t		{"LastDiscoveryAttempt":"2022-08-08T10:11:10.208211Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.7.0"}	
x3000c0s17b4	NodeBMC		x3000c0s17b4		x3000c0s17b4	{}	t	80694c6f-debf-0010-e903-b42e99dfec49	root		f	f	b42e99dfec49	t		{"LastDiscoveryAttempt":"2022-08-08T10:11:11.309254Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.7.0"}	
x3000c0s17b1	NodeBMC		x3000c0s17b1		x3000c0s17b1	{}	t	40f2306f-debf-0010-e903-b42e99dff361	root		f	f	b42e99dff361	t		{"LastDiscoveryAttempt":"2022-08-08T10:11:13.517207Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.7.0"}	
x3000c0s19b0	NodeBMC		x3000c0s19b0		x3000c0s19b0	{}	t	66499c32-a71e-5fd6-92a7-326fc4554681	root		f	f	9440c9376780	t		{"LastDiscoveryAttempt":"2022-08-08T10:11:26.807604Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000c0s2b0	NodeBMC				x3000c0s2b0	{}	t	b153a31c-300f-567d-9a76-5c0d0d006f58	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:35:36.177731Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000c0s4b0	NodeBMC				x3000c0s4b0	{}	t	c34e9bcc-0696-51b2-ab76-325e98d063dd	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:35:36.412148Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000c0s6b0	NodeBMC				x3000c0s6b0	{}	t	44b474f0-662c-52c2-9122-dc0daef6c5ec	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:54:57.564441Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000m1	CabinetPDUController		x3000m1		x3000m1	{}	t		root		f	f	ecebb83d88ff	t		{"LastDiscoveryAttempt":"2022-08-15T21:46:48.648008Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.2.0"}	
x3000c0s30b0	NodeBMC				x3000c0s30b0	{}	t	09a20d12-c349-599f-a9d3-633afbb122ed	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:36:43.771480Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
x3000m0	CabinetPDUController		x3000m0		x3000m0	{}	t		root		f	f	ecebb83d8941	t		{"LastDiscoveryAttempt":"2022-08-15T22:07:29.541572Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.0.0"}	
x3000c0s7b0	NodeBMC				x3000c0s7b0	{}	t	7fbe3c27-14f6-5e84-9d14-ae3aac5c506d	root		f	f		t		{"LastDiscoveryAttempt":"2022-08-26T16:35:37.755930Z","LastDiscoveryStatus":"DiscoverOK","RedfishVersion":"1.6.0"}	
\.


--
-- Data for Name: schema_migrations; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.schema_migrations (version, dirty) FROM stdin;
22	f
\.


--
-- Data for Name: scn_subscriptions; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.scn_subscriptions (id, sub_url, subscription) FROM stdin;
1	cray-hmnfd-565f796d-s5xh5_5http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-s5xh5_5","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
2	cray-hmnfd-565f796d-2q4p4_5http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-2q4p4_5","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
3	cray-hmnfd-565f796d-s5xh5_6http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-s5xh5_6","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
4	cray-hmnfd-565f796d-vr26h_4http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-vr26h_4","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
34	cray-hmnfd-565f796d-sf27v_4http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-sf27v_4","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
35	cray-hmnfd-565f796d-sf27v_5http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-sf27v_5","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
36	cray-hmnfd-565f796d-lppm5_7http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-lppm5_7","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
69	cray-hmnfd-565f796d-t6pxn_4http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-t6pxn_4","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
70	cray-hmnfd-565f796d-lppm5_8http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-565f796d-lppm5_8","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
71	cray-hmnfd-7c5b475bcc-nkhjw_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-nkhjw_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
72	cray-hmnfd-7c5b475bcc-jm69j_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-jm69j_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
73	cray-hmnfd-7c5b475bcc-l7ck6_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-l7ck6_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
74	cray-hmnfd-7c5b475bcc-jm69j_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-jm69j_2","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
75	cray-hmnfd-7c5b475bcc-nkhjw_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-nkhjw_2","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
76	cray-hmnfd-7c5b475bcc-l7ck6_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-l7ck6_2","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
77	cray-hmnfd-7c5b475bcc-qzqrv_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-qzqrv_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
78	cray-hmnfd-7c5b475bcc-qzqrv_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-qzqrv_2","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
79	cray-hmnfd-7c5b475bcc-6cndx_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-6cndx_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
112	cray-hmnfd-7c5b475bcc-z87cx_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-z87cx_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
145	cray-hmnfd-7c5b475bcc-kg7v8_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-kg7v8_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
146	cray-hmnfd-7c5b475bcc-djrvp_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-djrvp_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
147	cray-hmnfd-7c5b475bcc-l86bj_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-l86bj_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
148	cray-hmnfd-7c5b475bcc-fqb5t_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-fqb5t_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
149	cray-hmnfd-7c5b475bcc-djrvp_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-djrvp_2","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
150	cray-hmnfd-7c5b475bcc-fqb5t_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-fqb5t_2","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
183	cray-hmnfd-7c5b475bcc-vjn2z_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-vjn2z_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
184	cray-hmnfd-7c5b475bcc-bhqwc_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-bhqwc_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
185	cray-hmnfd-7c5b475bcc-djrvp_3http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-djrvp_3","SoftwareStatus":["dvsavailable","dvsunavailable"],"States":["ready","standby","halt"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
186	cray-hmnfd-7c5b475bcc-bhqwc_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-bhqwc_2","SoftwareStatus":["dvsavailable","dvsunavailable"],"States":["ready","standby","halt"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
187	cray-hmnfd-7c5b475bcc-vjn2z_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-vjn2z_2","SoftwareStatus":["dvsavailable","dvsunavailable"],"States":["ready","standby","halt"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
188	cray-hmnfd-7c5b475bcc-vjx2w_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-vjx2w_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
189	cray-hmnfd-7c5b475bcc-tbnqz_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-tbnqz_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
191	cray-hmnfd-7c5b475bcc-tbnqz_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-tbnqz_2","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
192	cray-hmnfd-7c5b475bcc-7zh4v_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-7zh4v_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
194	cray-hmnfd-7c5b475bcc-7zh4v_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-7zh4v_2","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
195	cray-hmnfd-7c5b475bcc-wlgs7_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-wlgs7_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
196	cray-hmnfd-7c5b475bcc-nq2lv_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-nq2lv_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
197	cray-hmnfd-7c5b475bcc-6l6bg_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-6l6bg_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
198	cray-hmnfd-7c5b475bcc-29z9r_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-29z9r_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
199	cray-hmnfd-7c5b475bcc-bhqwc_3http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-bhqwc_3","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
200	cray-hmnfd-7c5b475bcc-29z9r_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-29z9r_2","SoftwareStatus":["dvsavailable","dvsunavailable"],"States":["ready","standby","halt"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
201	cray-hmnfd-7c5b475bcc-hf6cc_1http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-hf6cc_1","Enabled":true,"Roles":["compute","service"],"States":["Empty","Populated","Off","On","Standby","Halt","Ready"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
202	cray-hmnfd-7c5b475bcc-hf6cc_2http://cray-hmnfd/hmi/v1/scn	{"Subscriber":"cray-hmnfd-7c5b475bcc-hf6cc_2","Enabled":true,"States":["on","off","empty","unknown","populated"],"Url":"http://cray-hmnfd/hmi/v1/scn"}
\.


--
-- Data for Name: service_endpoints; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.service_endpoints (rf_endpoint_id, redfish_type, redfish_subtype, uuid, odata_id, service_info) FROM stdin;
x3000m1	AccountService			/redfish/v1/AccountService	{"@odata.context":"","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_2_1.AccountService","Id":"AccountService","Name":"Account Service","Description":"BMC User Accounts","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"AuthFailureLoggingThreshold":3,"MinPasswordLength":8,"AccountLockoutThreshold":5,"AccountLockoutDuration":30,"AccountLockoutCounterResetAfter":30,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000m1	SessionService			/redfish/v1/SessionService	{"@odata.context":"","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_1_3.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":30,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000m1	EventService			/redfish/v1/EventService	{"@odata.context":"","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_5.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":""}}}
x3000m1	TaskService			/redfish/v1/TaskService	{"@odata.context":"","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_0.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2019-02-14T10:16:47Z","CompletedTaskOverWritePolicy":"Oldest","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000m1	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"","@odata.etag":"W/\\"1550139147\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_2_0.UpdateService","Id":"UpdateService","Name":"Update Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/SimpleUpdate","title":"SimpleUpdate"}}}
x3000c0s2b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s2b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s9b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s5b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s8b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s8b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000m0	AccountService			href/redfish/v1/AccountService	{"@odata.context":"","@odata.id":"","@odata.type":"","Id":"","Name":"","Description":"","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":0,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":""},"Roles":{"@odata.id":""}}
x3000m0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.1.0.0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK"},"SessionTimeout":10,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000m0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.1.0.0.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":""},"ServiceEnabled":false,"DeliveryRetryAttempts":0,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":null,"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":""}}}
x3000c0s5b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s5b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s5b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s6b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s6b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s17b3	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"Redfish User Accounts","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"AuthFailureLoggingThreshold":3,"MinPasswordLength":8,"AccountLockoutThreshold":5,"AccountLockoutDuration":30,"AccountLockoutCounterResetAfter":30,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s17b3	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_1_5.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":30,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s7b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s17b999	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"Redfish User Accounts","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"AuthFailureLoggingThreshold":3,"MinPasswordLength":8,"AccountLockoutThreshold":5,"AccountLockoutDuration":30,"AccountLockoutCounterResetAfter":30,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s17b999	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_1_5.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":30,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s17b999	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_3_0.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":null,"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s7b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s17b3	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_3.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-29T14:49:54+00:00","CompletedTaskOverWritePolicy":"Oldest","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s17b2	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"Redfish User Accounts","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"AuthFailureLoggingThreshold":3,"MinPasswordLength":8,"AccountLockoutThreshold":5,"AccountLockoutDuration":30,"AccountLockoutCounterResetAfter":30,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s17b2	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_1_5.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":30,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s17b999	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_3.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2020-09-03T23:07:26+00:00","CompletedTaskOverWritePolicy":"Oldest","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s4b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s4b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s4b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s4b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-26T16:35:17Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s4b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s17b2	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_3_0.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":null,"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s17b2	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_3.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-08T10:10:12+00:00","CompletedTaskOverWritePolicy":"Oldest","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s17b2	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"1611693995\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_5_0.UpdateService","Id":"UpdateService","Name":"Update Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/SimpleUpdate"}}}
x3000c0s17b4	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"Redfish User Accounts","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"AuthFailureLoggingThreshold":3,"MinPasswordLength":8,"AccountLockoutThreshold":5,"AccountLockoutDuration":30,"AccountLockoutCounterResetAfter":30,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s17b4	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_1_5.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":30,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s17b4	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_3_0.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":null,"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s17b4	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_3.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-08T10:10:14+00:00","CompletedTaskOverWritePolicy":"Oldest","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s17b4	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"1634665171\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_5_0.UpdateService","Id":"UpdateService","Name":"Update Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/SimpleUpdate"}}}
x3000c0s5b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-26T16:35:18Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s30b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s6b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s17b999	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"1550916377\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_5_0.UpdateService","Id":"UpdateService","Name":"Update Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/SimpleUpdate"}}}
x3000c0s17b1	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"Redfish User Accounts","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"AuthFailureLoggingThreshold":3,"MinPasswordLength":8,"AccountLockoutThreshold":5,"AccountLockoutDuration":30,"AccountLockoutCounterResetAfter":30,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s17b1	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_1_5.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":30,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s17b1	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_3_0.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":null,"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s17b1	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_3.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-08T10:10:24+00:00","CompletedTaskOverWritePolicy":"Oldest","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s17b1	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"946688212\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_5_0.UpdateService","Id":"UpdateService","Name":"Update Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/SimpleUpdate"}}}
x3000c0s19b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_3_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":0,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s19b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s19b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s19b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-08T10:10:07Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s19b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"886F108C\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0r15b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_1_3.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":30,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s7b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-26T16:35:19Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s9b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s9b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s9b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-26T16:35:18Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s7b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s7b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s3b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"/redfish/v1/$metadata#AccountService.AccountService","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_5_0.AccountService","Id":"AccountService","Name":"Account Service","Description":"iLO User Accounts","Status":{"Health":""},"AuthFailureLoggingThreshold":0,"MinPasswordLength":8,"AccountLockoutThreshold":0,"AccountLockoutDuration":0,"AccountLockoutCounterResetAfter":0,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0s3b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s2b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s2b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-26T16:35:20Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0r15b0	AccountService			/redfish/v1/AccountService	{"@odata.context":"","@odata.id":"/redfish/v1/AccountService","@odata.type":"#AccountService.v1_2_1.AccountService","Id":"AccountService","Name":"Account Service","Description":"BMC User Accounts","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"AuthFailureLoggingThreshold":3,"MinPasswordLength":8,"AccountLockoutThreshold":5,"AccountLockoutDuration":30,"AccountLockoutCounterResetAfter":30,"Accounts":{"@odata.id":"/redfish/v1/AccountService/Accounts"},"Roles":{"@odata.id":"/redfish/v1/AccountService/Roles"}}
x3000c0r15b0	EventService			/redfish/v1/EventService	{"@odata.context":"","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_5.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":""}}}
x3000c0s30b0	SessionService			/redfish/v1/SessionService	{"@odata.context":"/redfish/v1/$metadata#SessionService.SessionService","@odata.id":"/redfish/v1/SessionService","@odata.type":"#SessionService.v1_0_0.SessionService","Id":"SessionService","Name":"Session Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"SessionTimeout":0,"Sessions":{"@odata.id":"/redfish/v1/SessionService/Sessions"}}
x3000c0s30b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s3b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s2b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s9b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0r15b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_0.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2019-02-14T11:07:31Z","CompletedTaskOverWritePolicy":"Oldest","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s30b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-26T16:35:17Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0r15b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"","@odata.etag":"W/\\"1550142436\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_2_0.UpdateService","Id":"UpdateService","Name":"Update Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/SimpleUpdate","title":"SimpleUpdate"}}}
x3000c0s6b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s8b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-26T16:35:17Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s8b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s3b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"2022-08-26T16:35:18Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s3b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s30b0	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"15AD0341\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_1_1.UpdateService","Id":"UpdateService","Name":"Update Service","ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"SoftwareInventory":{"@odata.id":"/redfish/v1/UpdateService/SoftwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"}},"HttpPushUri":"/cgi-bin/uploadFile"}
x3000c0s6b0	TaskService			/redfish/v1/TaskService	{"@odata.context":"/redfish/v1/$metadata#TaskService.TaskService","@odata.id":"/redfish/v1/TaskService","@odata.type":"#TaskService.v1_1_1.TaskService","Id":"TaskService","Name":"Task Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DateTime":"1970-01-01T00:03:49Z","CompletedTaskOverWritePolicy":"Manual","LifeCycleEventOnTaskStateChange":true,"Tasks":{"@odata.id":"/redfish/v1/TaskService/Tasks"}}
x3000c0s8b0	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_0_8.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","HealthRollUp":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":["StatusChange","ResourceUpdated","ResourceAdded","ResourceRemoved","Alert"],"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s17b3	EventService			/redfish/v1/EventService	{"@odata.context":"/redfish/v1/$metadata#EventService.EventService","@odata.id":"/redfish/v1/EventService","@odata.type":"#EventService.v1_3_0.EventService","Id":"EventService","Name":"Event Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"DeliveryRetryAttempts":3,"DeliveryRetryIntervalInSeconds":0,"EventTypesForSubscription":null,"EventTypesForSubscription@odata.count":0,"Subscriptions":{"@odata.id":"/redfish/v1/EventService/Subscriptions"},"Actions":{"#EventService.SubmitTestEvent":{"EventType@Redfish.AllowableValues":null,"target":"/redfish/v1/EventService/Actions/EventService.SubmitTestEvent"}}}
x3000c0s17b3	UpdateService			/redfish/v1/UpdateService	{"@odata.context":"/redfish/v1/$metadata#UpdateService.UpdateService","@odata.etag":"W/\\"1625624576\\"","@odata.id":"/redfish/v1/UpdateService","@odata.type":"#UpdateService.v1_5_0.UpdateService","Id":"UpdateService","Name":"Update Service","Status":{"Health":"OK","State":"Enabled"},"ServiceEnabled":true,"FirmwareInventory":{"@odata.id":"/redfish/v1/UpdateService/FirmwareInventory"},"Actions":{"#UpdateService.SimpleUpdate":{"target":"/redfish/v1/UpdateService/Actions/SimpleUpdate"}}}
\.


--
-- Data for Name: system; Type: TABLE DATA; Schema: public; Owner: hmsdsuser
--

COPY public.system (id, schema_version, system_info) FROM stdin;
0	20	{}
\.


--
-- Name: scn_subscriptions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: hmsdsuser
--

SELECT pg_catalog.setval('public.scn_subscriptions_id_seq', 234, true);


--
-- Name: comp_endpoints comp_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.comp_endpoints
    ADD CONSTRAINT comp_endpoints_pkey PRIMARY KEY (id);


--
-- Name: comp_eth_interfaces comp_eth_interfaces_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.comp_eth_interfaces
    ADD CONSTRAINT comp_eth_interfaces_pkey PRIMARY KEY (id);


--
-- Name: component_group_members component_group_members_component_id_group_namespace_key; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.component_group_members
    ADD CONSTRAINT component_group_members_component_id_group_namespace_key UNIQUE (component_id, group_namespace);


--
-- Name: component_group_members component_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.component_group_members
    ADD CONSTRAINT component_group_members_pkey PRIMARY KEY (component_id, group_id);


--
-- Name: component_groups component_groups_name_namespace_key; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.component_groups
    ADD CONSTRAINT component_groups_name_namespace_key UNIQUE (name, namespace);


--
-- Name: component_groups component_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.component_groups
    ADD CONSTRAINT component_groups_pkey PRIMARY KEY (id);


--
-- Name: components components_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.components
    ADD CONSTRAINT components_pkey PRIMARY KEY (id);


--
-- Name: discovery_status discovery_status_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.discovery_status
    ADD CONSTRAINT discovery_status_pkey PRIMARY KEY (id);


--
-- Name: hsn_interfaces hsn_interfaces_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.hsn_interfaces
    ADD CONSTRAINT hsn_interfaces_pkey PRIMARY KEY (nic);


--
-- Name: hwinv_by_fru hwinv_by_fru_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.hwinv_by_fru
    ADD CONSTRAINT hwinv_by_fru_pkey PRIMARY KEY (fru_id);


--
-- Name: hwinv_by_loc hwinv_by_loc_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.hwinv_by_loc
    ADD CONSTRAINT hwinv_by_loc_pkey PRIMARY KEY (id);


--
-- Name: job_state_rf_poll job_state_rf_poll_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.job_state_rf_poll
    ADD CONSTRAINT job_state_rf_poll_pkey PRIMARY KEY (comp_id);


--
-- Name: job_sync job_sync_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.job_sync
    ADD CONSTRAINT job_sync_pkey PRIMARY KEY (id);


--
-- Name: reservations locks_component_id_pk; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.reservations
    ADD CONSTRAINT locks_component_id_pk PRIMARY KEY (component_id);


--
-- Name: node_nid_mapping node_nid_mapping_nid_key; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.node_nid_mapping
    ADD CONSTRAINT node_nid_mapping_nid_key UNIQUE (nid);


--
-- Name: node_nid_mapping node_nid_mapping_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.node_nid_mapping
    ADD CONSTRAINT node_nid_mapping_pkey PRIMARY KEY (id);


--
-- Name: power_mapping power_mapping_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.power_mapping
    ADD CONSTRAINT power_mapping_pkey PRIMARY KEY (id);


--
-- Name: rf_endpoints rf_endpoints_fqdn_key; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.rf_endpoints
    ADD CONSTRAINT rf_endpoints_fqdn_key UNIQUE (fqdn);


--
-- Name: rf_endpoints rf_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.rf_endpoints
    ADD CONSTRAINT rf_endpoints_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: scn_subscriptions scn_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.scn_subscriptions
    ADD CONSTRAINT scn_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: scn_subscriptions scn_subscriptions_sub_url_key; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.scn_subscriptions
    ADD CONSTRAINT scn_subscriptions_sub_url_key UNIQUE (sub_url);


--
-- Name: service_endpoints service_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.service_endpoints
    ADD CONSTRAINT service_endpoints_pkey PRIMARY KEY (rf_endpoint_id, redfish_type);


--
-- Name: system system_pkey; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.system
    ADD CONSTRAINT system_pkey PRIMARY KEY (id);


--
-- Name: system system_schema_version_key; Type: CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.system
    ADD CONSTRAINT system_schema_version_key UNIQUE (schema_version);


--
-- Name: components_role_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX components_role_idx ON public.components USING btree (role);


--
-- Name: components_role_subrole_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX components_role_subrole_idx ON public.components USING btree (role, subrole);


--
-- Name: components_subrole_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX components_subrole_idx ON public.components USING btree (subrole);


--
-- Name: hwinvhist_event_type_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX hwinvhist_event_type_idx ON public.hwinv_hist USING btree (event_type);


--
-- Name: hwinvhist_fru_id_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX hwinvhist_fru_id_idx ON public.hwinv_hist USING btree (fru_id);


--
-- Name: hwinvhist_id_fruid_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX hwinvhist_id_fruid_idx ON public.hwinv_hist USING btree (id, fru_id);


--
-- Name: hwinvhist_id_fruid_ts_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX hwinvhist_id_fruid_ts_idx ON public.hwinv_hist USING btree (id, fru_id, "timestamp");


--
-- Name: hwinvhist_id_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX hwinvhist_id_idx ON public.hwinv_hist USING btree (id);


--
-- Name: hwinvhist_timestamp_idx; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX hwinvhist_timestamp_idx ON public.hwinv_hist USING btree ("timestamp");


--
-- Name: locks_create_timestamp_index; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX locks_create_timestamp_index ON public.reservations USING btree (create_timestamp);


--
-- Name: locks_deputy_key_index; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX locks_deputy_key_index ON public.reservations USING btree (deputy_key);


--
-- Name: locks_expiration_timestamp_index; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX locks_expiration_timestamp_index ON public.reservations USING btree (expiration_timestamp);


--
-- Name: locks_reservation_key_index; Type: INDEX; Schema: public; Owner: hmsdsuser
--

CREATE INDEX locks_reservation_key_index ON public.reservations USING btree (reservation_key);


--
-- Name: comp_endpoints comp_endpoints_rf_endpoint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.comp_endpoints
    ADD CONSTRAINT comp_endpoints_rf_endpoint_id_fkey FOREIGN KEY (rf_endpoint_id) REFERENCES public.rf_endpoints(id) ON DELETE CASCADE;


--
-- Name: component_group_members component_group_members_component_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.component_group_members
    ADD CONSTRAINT component_group_members_component_id_fkey FOREIGN KEY (component_id) REFERENCES public.components(id) ON DELETE CASCADE;


--
-- Name: component_group_members component_group_members_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.component_group_members
    ADD CONSTRAINT component_group_members_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.component_groups(id) ON DELETE CASCADE;


--
-- Name: hwinv_by_loc hwinv_by_loc_fru_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.hwinv_by_loc
    ADD CONSTRAINT hwinv_by_loc_fru_id_fkey FOREIGN KEY (fru_id) REFERENCES public.hwinv_by_fru(fru_id);


--
-- Name: job_state_rf_poll job_state_rf_poll_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.job_state_rf_poll
    ADD CONSTRAINT job_state_rf_poll_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.job_sync(id) ON DELETE CASCADE;


--
-- Name: reservations locks_hardware_component_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.reservations
    ADD CONSTRAINT locks_hardware_component_id_fk FOREIGN KEY (component_id) REFERENCES public.components(id) ON DELETE CASCADE;


--
-- Name: service_endpoints service_endpoints_rf_endpoint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: hmsdsuser
--

ALTER TABLE ONLY public.service_endpoints
    ADD CONSTRAINT service_endpoints_rf_endpoint_id_fkey FOREIGN KEY (rf_endpoint_id) REFERENCES public.rf_endpoints(id) ON DELETE CASCADE;


--
-- Name: SCHEMA metric_helpers; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA metric_helpers TO admin;
GRANT USAGE ON SCHEMA metric_helpers TO robot_zmon;


--
-- Name: SCHEMA user_management; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA user_management TO admin;


--
-- Name: FUNCTION get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean); Type: ACL; Schema: metric_helpers; Owner: postgres
--

REVOKE ALL ON FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) TO admin;
GRANT ALL ON FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) TO robot_zmon;


--
-- Name: FUNCTION get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean); Type: ACL; Schema: metric_helpers; Owner: postgres
--

REVOKE ALL ON FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) TO admin;
GRANT ALL ON FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) TO robot_zmon;


--
-- Name: FUNCTION pg_stat_statements(showtext boolean); Type: ACL; Schema: metric_helpers; Owner: postgres
--

REVOKE ALL ON FUNCTION metric_helpers.pg_stat_statements(showtext boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION metric_helpers.pg_stat_statements(showtext boolean) TO admin;
GRANT ALL ON FUNCTION metric_helpers.pg_stat_statements(showtext boolean) TO robot_zmon;


--
-- Name: FUNCTION pg_stat_statements_reset(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.pg_stat_statements_reset() TO admin;


--
-- Name: FUNCTION set_user(text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.set_user(text) TO admin;


--
-- Name: FUNCTION create_application_user(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.create_application_user(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.create_application_user(username text) TO admin;


--
-- Name: FUNCTION create_application_user_or_change_password(username text, password text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.create_application_user_or_change_password(username text, password text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.create_application_user_or_change_password(username text, password text) TO admin;


--
-- Name: FUNCTION create_role(rolename text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.create_role(rolename text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.create_role(rolename text) TO admin;


--
-- Name: FUNCTION create_user(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.create_user(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.create_user(username text) TO admin;


--
-- Name: FUNCTION drop_role(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.drop_role(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.drop_role(username text) TO admin;


--
-- Name: FUNCTION drop_user(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.drop_user(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.drop_user(username text) TO admin;


--
-- Name: FUNCTION revoke_admin(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.revoke_admin(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.revoke_admin(username text) TO admin;


--
-- Name: FUNCTION terminate_backend(pid integer); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.terminate_backend(pid integer) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.terminate_backend(pid integer) TO admin;


--
-- Name: TABLE index_bloat; Type: ACL; Schema: metric_helpers; Owner: postgres
--

GRANT SELECT ON TABLE metric_helpers.index_bloat TO admin;
GRANT SELECT ON TABLE metric_helpers.index_bloat TO robot_zmon;


--
-- Name: TABLE pg_stat_statements; Type: ACL; Schema: metric_helpers; Owner: postgres
--

GRANT SELECT ON TABLE metric_helpers.pg_stat_statements TO admin;
GRANT SELECT ON TABLE metric_helpers.pg_stat_statements TO robot_zmon;


--
-- Name: TABLE table_bloat; Type: ACL; Schema: metric_helpers; Owner: postgres
--

GRANT SELECT ON TABLE metric_helpers.table_bloat TO admin;
GRANT SELECT ON TABLE metric_helpers.table_bloat TO robot_zmon;


--
-- Name: TABLE pg_stat_activity; Type: ACL; Schema: pg_catalog; Owner: postgres
--

GRANT SELECT ON TABLE pg_catalog.pg_stat_activity TO admin;


--
-- PostgreSQL database dump complete
--

