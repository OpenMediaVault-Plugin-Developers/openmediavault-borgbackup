<?php
/*
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2026 openmediavault plugin developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

class OMVRpcServiceBorgBackup extends \OMV\Rpc\ServiceAbstract
{
    private $getProgram = '/usr/bin/borg';
    private $envFile = '/etc/borgbackup/borg-envvar-';

    public function getName()
    {
        return 'BorgBackup';
    }

    public function initialize()
    {
        $this->registerMethod('enumerateRepoCandidates');
        $this->registerMethod('getRepoList');
        $this->registerMethod('getRepo');
        $this->registerMethod('setRepo');
        $this->registerMethod('changeRepoPath');
        $this->registerMethod('changeQuota');
        $this->registerMethod('downloadKey');
        $this->registerMethod('deleteRepo');
        $this->registerMethod('repoCommand');
        $this->registerMethod('mountRepo');
        $this->registerMethod('unmountRepo');
        $this->registerMethod('changePassphrase');

        $this->registerMethod('getArchiveList');
        $this->registerMethod('getArchive');
        $this->registerMethod('setArchive');
        $this->registerMethod('deleteArchive');
        $this->registerMethod('createArchive');
        $this->registerMethod('archiveCommand');
        $this->registerMethod('enumerateArchives');
        $this->registerMethod('exportArchive');
        $this->registerMethod('extractArchive');
        $this->registerMethod('getLog');

        $this->registerMethod('getEnvVarList');
        $this->registerMethod('getEnvVar');
        $this->registerMethod('setEnvVar');
        $this->registerMethod('deleteEnvVar');
    }

    public function enumerateRepoCandidates($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $repos = $db->getAssoc('conf.service.borgbackup.repo');
        if ($params['creation'] == true) {
            $repos[] = [
                'name' => 'Repo creation',
                'uuid' => 'creation'
            ];
        }
        return $repos;
    }

    public function getRepoList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get('conf.service.borgbackup.repo');
        $archives = $db->get('conf.service.borgbackup.archive');
        // Add additional share informations.
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            // Add the new property 'sharedfoldername'.
            $objectv->add('sharedfoldername', 'string', gettext("n/a"));
            if ($objectv->get('type') == 'local') {
                // Get the shared folder configuration object.
                $sfObject = $db->get('conf.system.sharedfolder',
                    $objectv->get('sharedfolderref'));
                // Update the 'sharedfoldername' property.
                $objectv->set('sharedfoldername', $sfObject->get('name'));
                $objectv->set('uri', gettext("n/a"));
            }
            // Add the new property 'mounted'.
            $cmd = sprintf('grep -E "^borgfs.*%s.*fuse" /proc/mounts', $objectv->get('name'));
            exec($cmd, $output, $return);
            $objectv->add('mounted', 'boolean', ! $return);
            $archiveCount = 0;
            foreach ($archives as $archivek => $archivev) {
                if ($archivev->get('reporef') == $objectv->get('uuid')) {
                    $archiveCount++;
                }
            }
            $objectv->add('archiveCount', 'integer', $archiveCount);
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.borgbackup.repo', $params['uuid']);
    }

    public function setRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.setrepo');
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.borgbackup.repo');
        // Remove spaces from name
        $params['name'] = str_replace(' ', '_', $params['name']);
        $params['storquota'] = trim($params['storquota']);
        // Clear uri if type is local
        if ($params['type'] == 'local') {
            $params['uri'] = '';
        }
        $object->setAssoc($params);
        // Check if new repo
        $isNew = $object->isNew();
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $isNew) {
            // Check uniqueness - name, Shared folder or uri
            $db->assertIsUnique($object, 'name');
            if ($params['type'] == 'local') {
                $db->assertIsUnique($object, 'sharedfolderref');
            } else {
                $db->assertIsUnique($object, 'uri');
            }
        }
        // initialize repo
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        if ($params['skipinit'] == true) {
            $cmdArgs[] = 'list';
            $cmdArgs[] = '--consider-checkpoints';
            $cmdArgs[] = '--short';
        } else {
            $cmdArgs[] = 'init';
            if ($params['encryption'] == true) {
                $cmdArgs[] = '--encryption=keyfile';
            } else {
                $cmdArgs[] = '--encryption=none';
            }
            if ($params['storquota'] !== '') {
                $cmdArgs[] = sprintf('--storage-quota %s', $params['storquota']);
            }
        }
        if ($params['type'] == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $params['sharedfolderref']
            ], $context);
        } else {
            $path = $params['uri'];
        }
        $cmdArgs[] = escapeshellarg($path);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($params['passphrase']), TRUE);
        $cmd->setEnv("BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK", "yes");
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        if ($params['skipinit'] == true) {
            $cmd->setEnv("BORG_RELOCATED_REPO_ACCESS_IS_OK", "yes");
        }
        if (!$isNew) {
            $cmd->setEnvFromFile($this->envFile . $params['uuid']);
        }
        $cmd->setEnvFromFile($this->envFile . 'creation');
        $cmd->setRedirect2to1();
        $cmdLine = $cmd->getCommandLine();
        if (0 !== $this->exec($cmdLine, $output)) {
            throw new \OMV\ExecException($cmd, $output);
        }
        // Remove skipinit parameter
        $object->remove('skipinit');
        // Set the configuration object.
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function changeRepoPath($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        //$this->validateMethodParams($params, 'rpc.borgbackup.changerepo');
        // get database object
        $db = \OMV\Config\Database::getInstance();
        // Clear uri if type is local
        $local = false;
        if ($params['type'] == 'local') {
            $params['uri'] = '';
            $local = true;
        }
        // get password and encryption params
        $other = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        $passphrase = $other->get('passphrase');
        $encryption = $other->get('encryption');
        $params['passphrase'] = $passphrase;
        $params['encryption'] = $encryption;
        // Prepare the configuration object.
        $repo = new \OMV\Config\ConfigObject("conf.service.borgbackup.repo");
        $repo->setAssoc($params);
        // Set the configuration object.
        // Check uniqueness - Shared folder or uri
        if ($local) {
            $db->assertIsUnique($repo, 'sharedfolderref');
        } else {
            $db->assertIsUnique($repo, 'uri');
        }
        // initialize repo
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'info';
        if ($local) {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $params['sharedfolderref']
            ], $context);
        } else {
            $path = $params['uri'];
        }
        $cmdArgs[] = escapeshellarg($path);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($passphrase), TRUE);
        $cmd->setEnv("BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK", "yes");
        $cmd->setEnv("BORG_RELOCATED_REPO_ACCESS_IS_OK", "yes");
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $params['uuid']);
        $cmd->setEnvFromFile($this->envFile . 'creation');
        $cmd->setRedirect2to1();
        $cmdLine = $cmd->getCommandLine();
        if (0 !== $this->exec($cmdLine, $output)) {
            throw new \OMV\ExecException($cmd, $output);
        }
        // Remove skipinit parameter
        $repo->remove('skipinit');
        // Set the configuration object.
        $db->set($repo);
        // Return the configuration object.
        return $repo->getAssoc();
    }

    public function changeQuota($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        //$this->validateMethodParams($params, 'rpc.borgbackup.changequota');
        $newquota = $params['newquota'];
        // get database object
        $db = \OMV\Config\Database::getInstance();
        // get password and encryption params
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        $passphrase = $repo->get('passphrase');
        $sfref = $repo->get('sharedfolderref');
        // change quota for the repo
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'config';
        $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', ['uuid' => $sfref], $context);
        $cmdArgs[] = escapeshellarg($path);
        $cmdArgs[] = sprintf('storage_quota %s', $newquota);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($passphrase), TRUE);
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $params['uuid']);
        $cmd->setRedirect2to1();
        $cmdLine = $cmd->getCommandLine();
        if (0 !== $this->exec($cmdLine, $output)) {
            throw new \OMV\ExecException($cmd, $output);
        }
        // update database
        $repo->set('storquota', $newquota);
        // Set the configuration object.
        $db->set($repo);
        // Return the configuration object.
        return $repo->getAssoc();
    }

    public function mountRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.mountrepo');
        // Prepare the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        // mount repo
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'mount';
        $vers = '';
        if ($params['versions']) {
            $vers = ',versions';
        }
        $cmdArgs[] = sprintf('-o allow_other%s', $vers);
        // repo path
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
            $path = str_replace('//', '/', $path);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = escapeshellarg($path);
        // mountpoint path
        $mntpath = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
            'uuid' => $params['sharedfolderref']
        ], $context);
        $mntpath = sprintf('%s/%s', $mntpath, $repo->get('name'));
        $mntpath = str_replace('//', '/', $mntpath);
        mkdir($mntpath, 0775, true);
        $cmdArgs[] = escapeshellarg($mntpath);
        // execute command
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $params['uuid']);
        $cmd->setRedirect2to1();
        $cmdLine = $cmd->getCommandLine();
        if (0 !== $this->exec($cmdLine, $output)) {
            throw new \OMV\ExecException($cmd, $output);
        }
        // Return the configuration object.
        return $repo->getAssoc();
    }

    public function unmountRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Prepare the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        $repoName = $repo->get('name');
        $len = strlen($repoName);
        // get repo directory
        $mounts = file_get_contents('/proc/mounts');
        $lines = explode(PHP_EOL, $mounts);
        $repoDir = '';
        foreach ($lines as $line) {
            $item = explode(' ', $line);
            if ($item[0] === 'borgfs' && $item[2] == 'fuse' && substr($item[1], -$len) === $repoName) {
                $repoDir = $item[1];
                break;
            }
        }
        // unmount repo
        if ($repoDir !== '') {
            $cmdArgs = [];
            $cmdArgs[] = $this->getProgram;
            $cmdArgs[] = 'umount';
            $cmdArgs[] = $repoDir;
            $cmd = new \OMV\System\Process($cmdArgs);
            $cmd->setEnv('BORG_PASSPHRASE', escapeshellarg($repo->get('passphrase')), TRUE);
            $cmd->setEnv("BORG_EXIT_CODES", "modern");
            $cmd->setEnvFromFile($this->envFile . $params['uuid']);
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();
            if (0 !== $this->exec($cmdLine, $output)) {
                throw new \OMV\ExecException($cmd, $output);
            }
            if (!rmdir($repoDir)) {
                throw new \OMV\ExecException(gettext("Failed to remove ") . $repoDir);
            }
        } else {
            throw new \OMV\ExecException(gettext("Failed to find ") . $repoDir);
        }
    }

    public function changePassphrase($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.changepassphrase');
        // Prepare the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        $repo->remove('skipinit');
        // change repo passphrase
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'key';
        $cmdArgs[] = 'change-passphrase';
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = $path;
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
        $cmd->setEnv("BORG_NEW_PASSPHRASE", escapeshellarg($params['passphrase']), TRUE);
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $params['uuid']);
        $cmdLine = $cmd->getCommandLine();
        if (0 !== $this->exec($cmdLine, $output)) {
            throw new \OMV\ExecException($cmd, $output);
        }
        // update passphrase in database
        $repo->set('passphrase',$params['passphrase']);
        $db->set($repo);
        // Set borgbackup module to dirty
        $dispatcher = \OMV\Engine\Notify\Dispatcher::getInstance();
        $dispatcher->notify(OMV_NOTIFY_MODIFY,
            'org.openmediavault.conf.service.borgbackup');
    }

    public function downloadKey($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $uuid = $params['uuid'];
        // Prepare the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'info';
        $cmdArgs[] = '--json';
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
              'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = escapeshellarg($path);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $uuid);
        $cmd->setRedirect2to1();
        $cmdLine = $cmd->getCommandLine();
        if (0 !== ($exitStatus = $this->exec($cmd, $output, $bgOutputFilename))) {
            throw new \OMV\ExecException($cmd, $output);
        }
        $info = trim(implode(PHP_EOL, $output));
        $enc = '';
        $keyfile = '';
        if (preg_match('/\{.*\}/s', $info, $matches)) {
            $json = $matches[0];
            $key = json_decode($json);
            $enc = $key->encryption;
            $keyfile = $enc->keyfile;
        }
        if (!file_exists($keyfile)) {
            throw new \OMV\ExecException(gettext(
              "Failed to get keyfile!"
            ));
        }
        // Modify the file mode/owner to allow the WebGUI PHP backend to unlink it.
        $tmpFilePath = tempnam(sys_get_temp_dir(), 'borgkeyfile');
        copy($keyfile, $tmpFilePath);
        chmod($tmpFilePath, 0700);
        chown($tmpFilePath, \OMV\Environment::get('OMV_WEBGUI_FILE_OWNERGROUP_NAME'));
        // Return values required by generic download RPC implementation.
        return [
            'filename' => sprintf('%s.%s', basename($keyfile), 'keyfile'),
            'filepath' => $tmpFilePath,
            'unlink' => TRUE
        ];
    }

    public function deleteRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.deleterepo');
        $deleteFiles = $params['deleteFiles'];
        $uuid = $params['uuid'];
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        // check to see if archive is using repo to be deleted
        $archives = $db->get('conf.service.borgbackup.archive');
        $found = false;
        foreach ($archives as $archive) {
            $reporef = $archive->get('reporef');
            if ($reporef == $uuid) {
                if ($deleteFiles) {
                    $found = true;
                    break;
                } else {
                    $delarchive = $db->get('conf.service.borgbackup.archive', $archive->get('uuid'));
                    $db->delete($delarchive);
                }
            }
        }
        if ($found && $deleteFiles) {
            throw new \OMV\ExecException(gettext(
              "Repo is in use. Delete archives associated with this repo first!"
            ));
        }
        $repo = $db->get('conf.service.borgbackup.repo', $uuid);
        if ($deleteFiles) {
            // delete repo files
            $cmdArgs = [];
            $cmdArgs[] = $this->getProgram;
            $cmdArgs[] = 'delete';
            if ($repo->get('type') == 'local') {
                $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                    'uuid' => $repo->get('sharedfolderref')
                ], $context);
                $perms = fileperms($path);
                $owner = fileowner($path);
                $group = filegroup($path);
            } else {
                $path = $repo->get('uri');
            }
            $cmdArgs[] = escapeshellarg($path);
            $cmd = new \OMV\System\Process($cmdArgs);
            $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
            $cmd->setEnv("BORG_DELETE_I_KNOW_WHAT_I_AM_DOING", "YES");
            $cmd->setEnv("BORG_EXIT_CODES", "modern");
            $cmd->setEnvFromFile($this->envFile . $params['uuid']);
            $cmd->setQuiet(TRUE);
            $cmdLine = $cmd->getCommandLine();
            if (0 !== $this->exec($cmdLine, $output)) {
                throw new \OMV\ExecException($cmd, $output);
            }
        }
        // Delete the configuration object.
        $db->delete($repo);
        // recreate the directory that was deleted
        if ($repo->get('type') == 'local') {
            mkdir($path, $perms);
            chown($path, $owner);
            chgrp($path, $group);
        }
        // Return the deleted configuration object.
        return $repo->getAssoc();
    }

    public function repoCommand($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.cmd');
        // Prepare the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        // Create the background process.
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($context, $params, $repo) {
                // mount repo
                $cmdArgs = [];
                $cmdArgs[] = $this->getProgram;
                switch ($params['command']) {
                    case 'all':
                        $cmdArgs[] = 'check';
                        break;
                    case 'archives':
                        $cmdArgs[] = 'check';
                        $cmdArgs[] = '--archives-only';
                        break;
                    case 'compact':
                        $threshold = \OMV\Environment::getInteger("OMV_BORGBACKUP_COMPACT_THRESHOLD", 10);
                        $cmdArgs[] = 'compact';
                        $cmdArgs[] = '--progress';
                        if ($threshold > 0 && $threshold < 100 && $threshold != 10) {
                            $cmdArgs[] = sprintf('--threshold %d', $threshold);
                        }
                        break;
                    case 'info':
                        $cmdArgs[] = 'info';
                        break;
                    case 'list':
                        $cmdArgs[] = 'list';
                        break;
                    case 'repo':
                        $cmdArgs[] = 'check';
                        $cmdArgs[] = '--repository-only';
                        break;
                    case 'verify':
                        $cmdArgs[] = 'check';
                        $cmdArgs[] = '--verify-data';
                        break;
                }
                if ($params['command'] != 'info') {
                    $cmdArgs[] = '--info';
                }
                if ($repo->get('type') == 'local') {
                    $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                        'uuid' => $repo->get('sharedfolderref')
                    ], $context);
                } else {
                    $path = $repo->get('uri');
                }
                $cmdArgs[] = escapeshellarg($path);
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
                $cmd->setEnv("BORG_EXIT_CODES", "modern");
                $cmd->setEnvFromFile($this->envFile . $params['uuid']);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== ($exitStatus = $this->exec($cmd, $output, $bgOutputFilename))) {
                    throw new \OMV\ExecException($cmd, $output);
                }
                return $output;
            }
        );
    }

    public function getArchiveList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get('conf.service.borgbackup.archive');
        // Add additional share informations.
        $objectsAssoc = [];
        $labels = [
            'hourly'  => gettext("hourly"),
            'daily'   => gettext("daily"),
            'weekly'  => gettext("weekly"),
            'monthly' => gettext("monthly"),
            'yearly'  => gettext("yearly"),
        ];
        $periods = [
            'hourly'  => ['hour' => null,          'min' => 'hourlymin'],
            'daily'   => ['hour' => 'dailyhour',   'min' => 'dailymin'],
            'weekly'  => ['hour' => 'weeklyhour',  'min' => 'weeklymin'],
            'monthly' => ['hour' => 'monthlyhour', 'min' => 'monthlymin'],
            'yearly'  => ['hour' => 'yearlyhour',  'min' => 'yearlymin'],
        ];
        foreach ($objects as $objectk => &$objectv) {
            $repo = $db->get('conf.service.borgbackup.repo', $objectv->get('reporef'));
            // Add the new property - reponame
            $objectv->add('reponame', 'string', $repo->get('name'));
            $includes = str_replace([',', PHP_EOL], '<br />', $objectv->get('include'));
            // Add the new properties - includes and excludes
            $objectv->add('includes', 'string', $includes);
            $excludes = str_replace([',', PHP_EOL], '<br />', $objectv->get('exclude'));
            $objectv->add('excludes', 'string', $excludes);
            // Add the new property - crontimes
            $crontimes = [];
            foreach ($periods as $name => $fields) {
                if (!$objectv->get("{$name}enable")) {
                    continue;
                }
                if ($fields['hour']) {
                    $hour = sprintf('%02d', (int)$objectv->get($fields['hour']));
                } else {
                    $hour = '*';
                }
                $min = sprintf('%02d', (int)$objectv->get($fields['min']));
                $crontimes[] = sprintf('%s %s:%s', $labels[$name], $hour, $min);
            }
            $objectv->add('crontimes', 'string', implode('<br />', $crontimes));
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.borgbackup.archive', $params['uuid']);
        $includes = str_replace(',', PHP_EOL, $object->get("include"));
        $object->set("include", $includes);
        $excludes = str_replace(',', PHP_EOL, $object->get("exclude"));
        $object->set("exclude", $excludes);
        return $object->getAssoc();
    }

    public function setArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.setarchive');
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.borgbackup.archive');
        // Map periods in order of most frequent → least frequent
        $periods = ['hourly', 'daily', 'weekly', 'monthly', 'yearly'];
        // Determine if any enable flag is already true
        $anyEnabled = false;
        foreach ($periods as $period) {
            if (!empty($params["{$period}enable"])) {
                $anyEnabled = true;
                break;
            }
        }
        // If none enabled, enable most frequent period with value > 0
        if (!$anyEnabled) {
            foreach ($periods as $period) {
                $value = (int)($params[$period] ?? 0);
                if ($value > 0) {
                    $params["{$period}enable"] = true;
                    break;
                }
            }
        }
        // Remove spaces from name
        $params['name'] = str_replace(' ', '_', $params['name']);
        // format includes and excludes
        $params['include'] = $this->cleanArray($params['include']);
        $params['exclude'] = $this->cleanArray($params['exclude']);
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $isNew) {
            // Check uniqueness - Shared folder
            $db->assertIsUnique($object, 'name');
        }
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    private function cleanArray($csvList): string
    {
        $list = str_replace(',', PHP_EOL, $csvList);
        $list = explode(PHP_EOL, $list);
        $list = array_map('trim', $list);
        $list = array_filter($list, 'strlen');
        $list = array_unique($list);
        return (implode(',', $list));
    }

    public function createArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.createarchive');
        $db = \OMV\Config\Database::getInstance();
        // Get archive configuration object
        $archive = $db->get('conf.service.borgbackup.archive', $params['uuid']);
        // Get repo configuration object
        $repo = $db->get('conf.service.borgbackup.repo', $archive->get('reporef'));
        $dryrun = $params['dryrun'];
        $progress = $params['progress'];
        // Create the background process.
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($archive, $context, $repo, $dryrun, $progress) {
                // prescript
                $prescript = $archive->get('prescript');
                if (strlen($prescript) > 1) {
                    $cmd = new \OMV\System\Process($prescript);
                    $cmd->setEnvFromFile($this->envFile . $archive->get('reporef'));
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    $this->exec($cmdLine, $output, $bgOutputFilename);
                }
                // borg command
                $cmdArgs = [];
                $basedir = $archive->get('basedir');
                if (strlen($basedir) > 0) {
                    if (!is_dir($basedir)) {
                        throw new \OMV\ValueException(
                            sprintf('%s: %s', gettext("Directory not found"), $basedir)
                        );
                    }
                    $cmdArgs[] = sprintf('cd %s && ', escapeshellarg($basedir));
                }
                $cmdArgs[] = $this->getProgram;
                $cmdArgs[] = 'create';
                if ($dryrun) {
                    $cmdArgs[] = '--dry-run';
                }
                if ($archive->get('list') == true) {
                    $cmdArgs[] = '--list';
                }
                if (!$dryrun) {
                    $cmdArgs[] = '--stats';
                }
                $cmdArgs[] = '--verbose';
                if ($progress) {
                    $cmdArgs[] = '--progress';
                }
                $ct = $archive->get('compressiontype');
                if ($ct == 'none') {
                    $comp = $ct;
                } else {
                    $cr = $archive->get('compressionratio');
                    $comp = sprintf('auto,%s,%s', $ct, $cr);
                }
                $cmdArgs[] = sprintf('--compression %s', $comp);
                if ($repo->get('type') == 'local') {
                    $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                        'uuid' => $repo->get('sharedfolderref')
                    ], $context);
                } else {
                    if ($archive->get('ratelimit') > 0) {
                        $cmdArgs[] = '--upload-ratelimit ' . $archive->get('ratelimit');
                    }
                    $path = $repo->get('uri');
                }
                $cmdArgs[] = sprintf('"%s::%s-{now:%%Y-%%m-%%d_%%H-%%M-%%S}"', $path, $archive->get('name'));
                $includes = explode(',', $archive->get('include'));
                foreach ($includes as $dirs) {
                    $cmdArgs[] = escapeshellarg($dirs);
                }
                $excludes = explode(',', $archive->get('exclude'));
                foreach ($excludes as $dirs) {
                    $cmdArgs[] = sprintf('--exclude %s', escapeshellarg($dirs));
                }
                if ($archive->get('onefs') == true) {
                    $cmdArgs[] = '--one-file-system';
                }
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
                $cmd->setEnv("BORG_EXIT_CODES", "modern");
                $cmd->setEnvFromFile($this->envFile . $archive->get('reporef'));
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                $this->writeBgProcOutput($bgOutputFilename, sprintf('Command: %s', $cmd));
                $this->writeBgProcOutput($bgOutputFilename, PHP_EOL.PHP_EOL);
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmd, $output);
                }
                // post script
                $postscript = $archive->get('postscript');
                if (strlen($postscript) > 1) {
                    $cmd = new \OMV\System\Process($postscript);
                    $cmd->setEnvFromFile($this->envFile . $archive->get('reporef'));
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    $this->writeBgProcOutput($bgOutputFilename, PHP_EOL.PHP_EOL);
                    $this->exec($cmdLine, $output, $bgOutputFilename);
                }
                // return
                return $output;
            }
        );
    }

    public function deleteArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        $db = \OMV\Config\Database::getInstance();
        // Get archive configuration object
        $archive = $db->get('conf.service.borgbackup.archive', $params['uuid']);
        // Get repo configuration object
        $repo = $db->get('conf.service.borgbackup.repo', $archive->get('reporef'));
        // delete archive
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'delete';
        $cmdArgs[] = sprintf('--glob-archives "%s*"', $archive->get('name'));
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = escapeshellarg($path);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $archive->get('reporef'));
        $cmd->setQuiet(TRUE);
        $cmdLine = $cmd->getCommandLine();
        if (0 !== $this->exec($cmdLine, $output)) {
            throw new \OMV\ExecException($cmd, $output);
        }
        // Delete the configuration object.
        $db->delete($archive);
        // Return the deleted configuration object.
        return $archive->getAssoc();
    }

    public function archiveCommand($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.cmd');
        $db = \OMV\Config\Database::getInstance();
        // Get archive configuration object
        $archive = $db->get('conf.service.borgbackup.archive', $params['uuid']);
        // Get repo configuration object
        $repo = $db->get('conf.service.borgbackup.repo', $archive->get('reporef'));
        // Create the background process.
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($archive, $context, $params, $repo) {
                $cmdArgs = [];
                $cmdArgs[] = $this->getProgram;
                switch ($params['command']) {
                    case 'info':
                        $cmdArgs[] = 'info';
                        break;
                    case 'list':
                        $cmdArgs[] = 'list';
                        break;
                }
                if ($params['command'] != 'info') {
                    $cmdArgs[] = '--info';
                }
                if ($repo->get('type') == 'local') {
                    $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                        'uuid' => $repo->get('sharedfolderref')
                    ], $context);
                } else {
                    $path = $repo->get('uri');
                }
                if ($params['command'] == 'info') {
                    $cmdArgs[] = sprintf('"%s"', $path);
                    $cmdArgs[] = sprintf('--glob-archives "%s*"', $archive->get('name'));
                } else {
                    $cmdArgs[] = sprintf('"%s::%s"', $path, $archive->get('name'));
                }
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
                $cmd->setEnv("BORG_EXIT_CODES", "modern");
                $cmd->setEnvFromFile($this->envFile . $archive->get('reporef'));
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                $this->writeBgProcOutput($bgOutputFilename, sprintf('Command: %s', $cmd));
                $this->writeBgProcOutput($bgOutputFilename, PHP_EOL.PHP_EOL);
                if (0 !== ($exitStatus = $this->exec($cmd, $output, $bgOutputFilename))) {
                    throw new \OMV\ExecException($cmd, $output);
                }
                return $output;
            }
        );
    }

    public function enumerateArchives($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        $db = \OMV\Config\Database::getInstance();
        // Get archive configuration object
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        // get a list of archives in selected repo
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'list';
        $cmdArgs[] = '--short';
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = escapeshellarg($path);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
        $cmdLine = $cmd->getCommandLine();
        if (0 !== $this->exec($cmdLine, $output)) {
            throw new \OMV\ExecException($cmd, $output);
        }
        $archives = [];
        foreach ($output as $archive) {
            $archives[] = [
                'name' => $archive,
            ];
        }
        // Return the object.
        return $archives;
    }

    public function exportArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.export');
        $db = \OMV\Config\Database::getInstance();
        // Get repo configuration object
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'export-tar';
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $sfpath = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
            'uuid' => $params['sharedfolderref']
        ], $context);
        $cmdArgs[] = sprintf('"%s::%s"', $path, $params['archive']);
        $filename = str_replace(' ', '_', $params['archive']);
        $cmdArgs[] = sprintf('"%s/%s.tar.gz"', $sfpath, $filename);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
        $cmd->setQuiet(TRUE);
        $cmd->setBackground(TRUE);
        $cmdLine = $cmd->getCommandLine();
        $this->exec($cmdLine, $output);
    }

    public function extractArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.extract');
        $db = \OMV\Config\Database::getInstance();
        // Get repo configuration object
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        $logFile = sprintf("/tmp/omv-borg-extract-%s.log", $params['uuid']);
        $cmdArgs = [];
        if (($params['original'] == false) && (is_uuid($params['sharedfolderref']))) {
            $sfpath = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $params['sharedfolderref']
            ], $context);
        } else {
            $sfpath = '/';
        }
        $cmdArgs[] = sprintf('cd %s &&', escapeshellarg($sfpath));
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'extract';
        $cmdArgs[] = '--progress';
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = sprintf('"%s::%s"', $path, $params['archive']);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')), TRUE);
        $cmd->setEnv("BORG_EXIT_CODES", "modern");
        $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
        $cmd->setRedirect2to1();
        $cmd->setRedirect1toFile($logFile);
        $cmd->setBackground(TRUE);
        $cmdLine = $cmd->getCommandLine();
        if (0 !== $this->exec($cmdLine, $output)) {
            throw new \OMV\ExecException($cmd, $output);
        }
    }

    public function getLog($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $logFile = sprintf("/tmp/omv-borg-%s-%s.log", $params['command'], $params['uuid']);
                $cmdArgs = [];
                $cmdArgs[] = 'tail';
                $cmdArgs[] = '-n +1';
                if ($params['follow']) {
                    $cmdArgs[] = '-f';
                }
                $cmdArgs[] = $logFile;
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setQuiet(true);
                $cmdLine = $cmd->getCommandLine();
                if (file_exists($logFile)) {
                    $exitStatus = $this->exec($cmdLine, $output, $bgOutputFilename);
                }
                return $output;
            }
        );
    }

    public function getEnvVarList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get('conf.service.borgbackup.envvar');
        // Add additional environment variable informations.
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            // Add the new property 'sharedfoldername'.
            $objectv->add('reponame', 'string', gettext("n/a"));
            // Get the shared folder configuration object.
            if ($objectv->get('reporef') == 'creation') {
                $objectv->set('reponame', 'Repo creation');
            } else {
                try {
                    $repoObject = $db->get('conf.service.borgbackup.repo', $objectv->get('reporef'));
                    // Update the 'reponame' property.
                    $objectv->set('reponame', $repoObject->get('name'));
                } catch (Exception $e) {
                }
            }
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getEnvVar($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.borgbackup.envvar', $params['uuid']);
    }

    public function setEnvVar($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.setenvvar');
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.borgbackup.envvar');
        // Remove spaces from name
        $params['envname'] = str_replace(' ', '_', $params['envname']);
        // Set the configuration object.
        $object->setAssoc($params);
        $db = \OMV\Config\Database::getInstance();
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteEnvVar($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.borgbackup.envvar', $params['uuid']);
        // Delete the configuration object.
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }
}
