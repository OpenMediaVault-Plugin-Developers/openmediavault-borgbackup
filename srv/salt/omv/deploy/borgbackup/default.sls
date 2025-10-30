# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2025 openmediavault plugin developers
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

configure_borg_envvar_dir:
  file.directory:
    - name: "{{ envVarDir }}"
    - user: root
    - group: root
    - mode: 700

remove_envvar_files:
  module.run:
    - file.find:
      - path: "{{ envVarDir }}"
      - iname: "{{ envVarPrefix }}*"
      - delete: "f"

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

{% for dir in ['hourly','daily','weekly','monthly','yearly'] %}
configure_borg_{{ dir }}_dir:
  file.directory:
    - name: "/var/lib/openmediavault/borgbackup/{{ dir }}.d"
    - makedirs: True
    - clean: True
{% endfor %}

configure_borg_crond:
  file.managed:
    - name: "/etc/cron.d/openmediavault-borgbackup"
    - source:
      - salt://{{ tpldir }}/files/etc-cron_d-openmediavault-borgbackup.j2
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

{% set period = '' %}
{% if archive.hourly > 0 %}
{% set period = 'hourly' %}
{% elif archive.daily > 0 %}
{% set period = 'daily' %}
{% elif archive.weekly > 0 %}
{% set period = 'weekly' %}
{% elif archive.monthly > 0 %}
{% set period = 'monthly' %}
{% elif archive.yearly > 0 %}
{% set period = 'yearly' %}
{% endif %}

{% if period %}
{% set script = scriptsDir ~ '/' ~ period ~ '.d/' ~ scriptPrefix ~ archive.uuid %}

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

        # some helpers and error handling:
        info() { printf "\n%s %s\n\n" "$( date )" "$*"; }
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
          --remote-ratelimit {{ archive.ratelimit }} \
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

        # use highest exit code as global exit code
        global_exit=$backup_exit
        (( prune_exit > global_exit )) && global_exit=$prune_exit

        {%- if archive.compact | to_bool %}
        info "Compacting repository" {{ email }}
        borg compact --verbose --threshold {{ archive.cthreshold }} ${email}
        compact_exit=$?
        (( compact_exit > global_exit )) && global_exit=$compact_exit
        {% endif %}

        if [ ${global_exit} -eq 1 ]; then
          info "Backup, Prune, and/or Compact finished with a warning"
        fi

        if [ ${global_exit} -gt 1 ]; then
          info "Backup, Prune, and/or Compact finished with an error"
        fi

        exit ${global_exit}
    - user: root
    - group: root
    - mode: 750
{% endif %}
{% endfor %}
