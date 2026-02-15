# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2026 openmediavault plugin developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

{% set config = salt['omv_conf.get']('conf.service.borgbackup') %}
{% set envVarDir = '/etc/borgbackup' %}
{% set envVarPrefix = 'borg-envvar-' %}
{% set logFile = '/var/log/borgbackup.log' %}
{% set scriptsDir = '/var/lib/openmediavault/borgbackup' %}
{% set scriptPrefix = 'borgbackup-' %}

configure_borg_scripts_dir:
  file.directory:
    - name: "{{ scriptsDir }}"
    - makedirs: True
    - user: root
    - group: root
    - mode: 755

configure_borg_envvar_dir:
  file.directory:
    - name: "{{ envVarDir }}"
    - user: root
    - group: root
    - mode: 700

{% for repo in config.repos.repo %}
{% set envVarFile = envVarDir ~ '/' ~ envVarPrefix ~ repo.uuid %}

configure_borg_envvar_{{ repo.uuid }}:
  file.managed:
    - name: "{{ envVarFile }}"
    - source:
      - salt://{{ tpldir }}/files/etc-borgbackup-borg_envvar.j2
    - context:
        config: {{ config | json }}
        repouuid: {{ repo.uuid }}
    - template: jinja
    - user: root
    - group: root
    - mode: 600

{% endfor %}

{% set envVarFile = envVarDir ~ '/' ~ envVarPrefix ~ 'creation' %}
configure_borg_envvar_creation:
  file.managed:
    - name: "{{ envVarFile }}"
    - source:
      - salt://{{ tpldir }}/files/etc-borgbackup-borg_envvar.j2
    - context:
        config: {{ config | json }}
        repouuid: "creation"
    - template: jinja
    - user: root
    - group: root
    - mode: 600

configure_borg_crond:
  file.managed:
    - name: "/etc/cron.d/openmediavault-borgbackup"
    - source:
      - salt://{{ tpldir }}/files/etc-cron_d-openmediavault-borgbackup.j2
    - context:
        config: {{ config | json }}
        scriptsDir: {{ scriptsDir }}
        scriptPrefix: {{ scriptPrefix }}
    - template: jinja
    - user: root
    - group: root
    - mode: 644

{% set ns = namespace(type='',sharedfolderref='',uri='',passphrase='') %}

{% for archive in config.archives.archive | selectattr('enable') %}

{% for repo in config.repos.repo | selectattr("uuid", "equalto", archive.reporef) %}
{% set ns.type = repo.type %}
{% set ns.sharedfolderref = repo.sharedfolderref %}
{% set ns.uri = repo.uri %}
{% set ns.passphrase = repo.passphrase %}
{% endfor %}

{% set script = scriptsDir ~ '/' ~ scriptPrefix ~ archive.uuid %}

{% set rpath = '' %}
{% if ns.type == "local" %}
{% set rpath = salt['omv_conf.get_sharedfolder_path'](ns.sharedfolderref) %}
{% else %}
{% set rpath = ns.uri %}
{% endif %}

{% if archive.email %}
{% set email = '2>&1 | tee -a ' ~ logFile %}
{% else %}
{% set email = '>> ' ~ logFile ~ ' 2>&1' %}
{% endif %}

{% set extraEnv = envVarDir ~ '/' ~ envVarPrefix ~ archive.reporef %}

configure_borg_{{ archive.uuid }}_cron_file:
  file.managed:
    - name: '{{ script }}'
    - contents: |
        #!/bin/bash

        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}

        extra="{{ extraEnv }}"
        if [ -f "${extra}" ]; then
          set -a
          . ${extra}
          set +a
        fi

        # Setting this, so the repo does not need to be given on the commandline:
        export BORG_REPO='{{ rpath }}'

        # Setting this, so you won't be asked for your repository passphrase:
        export BORG_PASSPHRASE=$'{{ ns.passphrase | replace("'", "\\'") }}'

        # Wait up to 1 hour for repository/cache lock
        export BORG_LOCK_WAIT="${BORG_LOCK_WAIT:-3600}"

        # Use modern borg exit codes
        export BORG_EXIT_CODES=modern

        # some helpers
        log() {
          local level="${1}"
          shift
          printf '[%(%Y-%m-%d %H:%M:%S%z)T] %s: %s\n' -1 "${level}" "$*"
        }
        info()  { log INFO  "$@"; }
        warn()  { log WARN  "$@"; }
        error() { log ERROR "$@"; }

        # Serialize all operations per repo to avoid lock.exclusive contention
        lock_id="$(echo -n "${BORG_REPO}" | sha256sum | awk '{print $1}')"
        lockfile="/run/lock/omv-borg-${lock_id}.lock"

        mkdir -p /run/lock
        exec 9>"${lockfile}"

        info "Waiting for repo lock (${BORG_LOCK_WAIT}s): ${lockfile}" {{ email }}
        if ! flock -w "${BORG_LOCK_WAIT}" 9; then
          error "Failed to acquire outer repo lock after ${BORG_LOCK_WAIT}s: ${BORG_REPO}" {{ email }}
          exit 99
        fi
        info "Acquired outer repo lock: ${BORG_REPO}" {{ email }}

        # error handling
        trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM

        {%- if archive.prescript | length > 1 %}
        info "Executing pre-script" {{ email }}
        {{ archive.prescript }}
        {%- endif %}

        info "Starting backup" {{ email }}

        {%- if archive.basedir | length > 0 %}
        if [ -d "{{ archive.basedir }}" ]; then
          cd "{{ archive.basedir }}"
        else
          info "Directory not found - {{ archive.basedir }}"
          exit 127
        fi
        {%- endif %}

        borg create \
          --verbose \
          --filter AME \
        {%- if archive.list %}
          --list \
        {%- endif %}
          --stats \
          --show-rc \
        {%- if archive.onefs %}
          --one-file-system \
        {%- endif %}
        {%- if archive.compressiontype == 'none' %}
          --compression {{ archive.compressiontype }} \
        {%- else %}
          --compression auto,{{ archive.compressiontype }},{{ archive.compressionratio }} \
        {%- endif %}
        {%- if archive.ratelimit > 0 %}
          --upload-ratelimit {{ archive.ratelimit }} \
        {%- endif %}
          --exclude-caches \
        {%- if archive.exclude | length > 0 %}
        {%- set excludes = archive.exclude.split(',') | map('trim') | reject('equalto', '') %}
        {%- for exclude in excludes %}
          --exclude '{{ exclude }}' \
        {%- endfor %}
        {%- endif %}
          ::"{{ archive.name }}-{now:%Y-%m-%d_%H-%M-%S}" \
        {%- if archive.include | length > 0 %}
        {%- set includes = archive.include.split(',') | map('trim') | reject('equalto', '') %}
        {%- for include in includes %}
          '{{ include }}' \
        {%- endfor %}
        {%- endif %}
          {{ email }}

        backup_exit=$?

        {%- if archive.postscript | length > 1 %}
        info "Executing post-script" {{ email }}
        {{ archive.postscript }}
        {%- endif %}

        info "Pruning repository" {{ email }}

        borg prune \
          --list \
          --glob-archives '{{ archive.name }}-*' \
          --show-rc \
        {%- if archive.hourly > 0 %}
          --keep-hourly {{ archive.hourly }} \
        {%- endif %}
        {%- if archive.daily > 0 %}
          --keep-daily {{ archive.daily }} \
        {%- endif %}
        {%- if archive.weekly > 0 %}
          --keep-weekly {{ archive.weekly }} \
        {%- endif %}
        {%- if archive.monthly > 0 %}
          --keep-monthly {{ archive.monthly }} \
        {%- endif %}
        {%- if archive.yearly > 0 %}
          --keep-yearly {{ archive.yearly }} \
        {%- endif %}
          {{ email }}

        prune_exit=$?

        borg_rc_class() {
          local rc="${1}"
          if (( rc == 0 )); then
            echo ok
          elif (( rc == 1 )); then
            echo warn
          elif (( rc >= 2 && rc <= 99 )); then
            echo err
          elif (( rc >= 100 && rc <= 127 )); then
            echo warn
          elif (( rc >= 128 )); then
            echo sig
          else
            echo err
          fi
        }

        borg_rc_label() {
          local rc="${1}"
          case "$(borg_rc_class "${rc}")" in
            ok)   echo "ok" ;;
            warn) echo "warning(${rc})" ;;
            err)  echo "error(${rc})" ;;
            sig)  echo "terminated(${rc})" ;;
          esac
        }

        status_msgs=()
        overall=ok

        add_phase_status() {
          local phase="${1}"
          local rc="${2}"
          local cls
          cls="$(borg_rc_class "${rc}")"
          case "${cls}" in
            ok)
              return 0
              ;;
            warn)
              status_msgs+=( "${phase}=$(borg_rc_label "${rc}")" )
              [[ "${overall}" == "ok" ]] && overall=warn
              ;;
            err|sig)
              status_msgs+=( "${phase}=$(borg_rc_label "${rc}")" )
              overall=err
              ;;
          esac
        }

        {%- if archive.compact | to_bool %}
        info "Compacting repository" {{ email }}
        borg compact --verbose --threshold {{ archive.cthreshold }} {{email}}
        compact_exit=$?
        {%- else %}
        compact_exit=0
        {%- endif %}

        add_phase_status "backup" "${backup_exit}"
        add_phase_status "prune" "${prune_exit}"
        add_phase_status "compact" "${compact_exit}"

        case "${overall}" in
          ok)   global_exit=0 ;;
          warn) global_exit=1 ;;
          err)  global_exit=2 ;;
        esac

        if [[ "${overall}" == "ok" ]]; then
          info "Borg finished successfully" {{ email }}
        elif [[ "${overall}" == "warn" ]]; then
          warn "Borg finished with warnings: ${status_msgs[*]}" {{ email }}
        else
          error "Borg finished with errors: ${status_msgs[*]}" {{ email }}
        fi

        exit ${global_exit}
    - user: root
    - group: root
    - mode: 750
{% endfor %}


{% set keep_env = [] %}
{% for repo in config.repos.repo %}
{% do keep_env.append(envVarPrefix ~ repo.uuid) %}
{% endfor %}
{% do keep_env.append(envVarPrefix ~ 'creation') %}

purge_stale_borg_envvars:
  file.tidied:
    - name: "{{ envVarDir }}"
    - matches:
      - "{{ envVarPrefix }}.*"
    - exclude:
{%- for f in keep_env %}
      - "{{ f }}"
{%- endfor %}
    - rmdirs: False
    - rmlinks: True


{% set keep_scripts = [] %}
{% for archive in config.archives.archive | selectattr('enable') %}
{% do keep_scripts.append(scriptPrefix ~ archive.uuid) %}
{% endfor %}

purge_stale_borg_scripts:
  file.tidied:
    - name: "{{ scriptsDir }}"
    - matches:
      - "{{ scriptPrefix }}.*"
    - exclude:
{%- for f in keep_scripts %}
      - "{{ f }}"
{%- endfor %}
    - rmdirs: False
    - rmlinks: True
