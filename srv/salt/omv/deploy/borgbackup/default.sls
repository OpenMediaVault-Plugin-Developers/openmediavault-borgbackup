# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2020 OpenMediaVault Plugin Developers
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
{% set logFile = '/var/log/borgbackup.log' %}
{% set scriptsDir = '/var/lib/openmediavault/borgbackup' %}
{% set scriptPrefix = 'borgbackup-' %}

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

{% set script = scriptsDir + '/' + period + '.d/' + scriptPrefix + archive.uuid %}

{% set rpath = '' %}
{% if ns.type == "local" %}
{% set rpath = salt['omv_conf.get_sharedfolder_path'](ns.sharedfolderref) %}
{% else %}
{% set rpath = ns.uri %}
{% endif %}

configure_borg_{{ archive.name }}_cron_file:
  file.managed:
    - name: '{{ script }}'
    - contents: |
        #!/bin/sh
 
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}

        # Setting this, so the repo does not need to be given on the commandline:
        export BORG_REPO='{{ rpath }}'

        # Setting this, so you won't be asked for your repository passphrase:
        export BORG_PASSPHRASE='{{ ns.passphrase }}'

        # some helpers and error handling:
        info() { printf "\n%s %s\n\n" "$( date )" "$*" | tee -a ${LOG_FILE}; }
        cleanup() {
            exit_code=$?
            rm -f "/run/{{ scriptPrefix + archive.uuid }}"

            if [ ${exit_code} -ne 0 ]; then
                echo $( date ) Backup interrupted >&2
            fi

            exit ${exit_code}
        }
        trap cleanup EXIT INT TERM
        touch "/run/{{ scriptPrefix + archive.uuid }}"

        info "Starting backup"

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
          --compression auto,{{ archive.compressiontype }},{{ archive.compressionratio }} \
        {%- if archive.ratelimit > 0 %}
          --remote-ratelimit {{ archive.ratelimit }} \
        {%- endif %}
          --exclude-caches \
        {%- if archive.exclude | length > 0 %}
        {%- for exclude in archive.exclude.split(',') %}
          --exclude '{{ exclude }}' \
        {%- endfor %}
        {%- endif %}
          ::"{{ archive.name }}-{now:%Y-%m-%d_%H-%M-%S}" \
        {%- if archive.include | length > 0 %}
        {%- for include in archive.include.split(',') %}
          '{{ include }}' \
        {%- endfor %}
        {%- endif %}
          2>&1 | tee -a {{ logFile }}

        backup_exit=$?

        info "Pruning repository"

        borg prune \
          --list \
          --prefix '{{ archive.name }}-' \
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
          2>&1 | tee -a {{ logFile }}

        prune_exit=$?

        # use highest exit code as global exit code
        global_exit=$(( backup_exit > prune_exit ? backup_exit : prune_exit ))

        if [ ${global_exit} -eq 1 ]; then
          info "Backup and/or Prune finished with a warning"
        fi

        if [ ${global_exit} -gt 1 ]; then
          info "Backup and/or Prune finished with an error"
        fi

        exit ${global_exit}
    - user: root
    - group: root
    - mode: 750
{% endfor %}

