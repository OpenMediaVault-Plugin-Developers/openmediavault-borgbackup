<?php
/*
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2022 OpenMediaVault Plugin Developers
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
        $this->registerMethod('deleteRepo');
        $this->registerMethod('repoCommand');
        $this->registerMethod('mountRepo');
        $this->registerMethod('unmountRepo');

        $this->registerMethod('getArchiveList');
        $this->registerMethod('getArchive');
        $this->registerMethod('setArchive');
        $this->registerMethod('deleteArchive');
        $this->registerMethod('createArchive');
        $this->registerMethod('archiveCommand');
        $this->registerMethod('enumerateArchives');
        $this->registerMethod('exportArchive');
        $this->registerMethod('extractArchive');
    }

    public function enumerateRepoCandidates($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.borgbackup.repo');
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
            $cmdArgs[] = 'info';
        } else {
            $cmdArgs[] = 'init';
            if ($params['encryption'] == true) {
                $cmdArgs[] = '--encryption=keyfile';
            } else {
                $cmdArgs[] = '--encryption=none';
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
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($params['passphrase']));
        $cmd->setEnv("BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK", "yes");
        $cmd->setRedirect2to1();
        $cmdLine = $cmd->getCommandLine();
        $cmd->execute($output, $exitStatus);
        if (0 !== $exitStatus) {
            throw new \OMV\ExecException($cmdLine, $output);
        }
        // Remove skipinit parameter
        $object->remove('skipinit');
        // Set the configuration object.
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
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
        $cmdArgs[] = '-o allow_other';
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = escapeshellarg($path);
        $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
            'uuid' => $params['sharedfolderref']
        ], $context);
        $path = sprintf('%s/%s', $path, $repo->get('name'));
        mkdir($path, 0775, true);
        $cmdArgs[] = escapeshellarg($path);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
        $cmd->execute($output);
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
        // unmount repo
        $repoDir = sprintf('$(grep "^borgfs.*%s.*fuse" /proc/mounts | cut -d" " -f2 | head -n1)', $repo->get('name'));
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'umount';
        $cmdArgs[] = $repoDir;
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
        $cmd->execute($output);
        // Return the configuration object.
        //return $repo->getAssoc();
    }

    public function deleteRepo($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        // check to see if archive is using repo to be deleted
        $archives = $db->get('conf.service.borgbackup.archive');
        $found = false;
        foreach ($archives as $archive) {
            $reporef = $archive->get('reporef');
            if ($reporef == $params['uuid']) {
                $found = true;
                break;
            }
        }
        if ($found) {
            throw new \OMV\ExecException(gettext(
              "Repo is in use. Delete archives associated with this repo first!"
            ));
        }
        $repo = $db->get('conf.service.borgbackup.repo', $params['uuid']);
        // delete repo
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = 'delete';
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = escapeshellarg($path);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
        $cmd->setEnv("BORG_DELETE_I_KNOW_WHAT_I_AM_DOING", "YES");
        $cmd->setQuiet(TRUE);
        $cmd->execute($output);
        // Delete the configuration object.
        $db->delete($repo);
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
                $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                $this->exec($cmdLine, $output, $bgOutputFilename);
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
        foreach ($objects as $objectk => &$objectv) {
            $repo = $db->get('conf.service.borgbackup.repo', $objectv->get('reporef'));
            // Add the new property 'reponame'.
            $objectv->add('reponame', 'string', $repo->get('name'));
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
        return $db->getAssoc('conf.service.borgbackup.archive', $params['uuid']);
    }

    public function setArchive($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.borgbackup.setarchive');
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.borgbackup.archive');
        // Remove spaces from name
        $params['name'] = str_replace(' ', '_', $params['name']);
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

    public function createArchive($params, $context)
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
        // Create the background process.
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($archive, $context, $repo) {
                $cmdArgs = [];
                $cmdArgs[] = $this->getProgram;
                $cmdArgs[] = 'create';
                if ($archive->get('list') == true) {
                    $cmdArgs[] = '--list';
                }
                $cmdArgs[] = '--stats';
                $cmdArgs[] = '--verbose';
                $cmdArgs[] = sprintf('--compression auto,%s,%s', $archive->get('compressiontype'),
                    $archive->get('compressionratio')
                );
                if ($repo->get('type') == 'local') {
                    $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                        'uuid' => $repo->get('sharedfolderref')
                    ], $context);
                } else {
                    if ($archive->get('ratelimit') > 0) {
                        $cmdArgs[] = '--remote-ratelimit ' . $archive->get('ratelimit');
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
                if ($archive->get('noatime') == true) {
                    $cmdArgs[] = '--noatime';
                }
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                $this->writeBgProcOutput($bgOutputFilename, sprintf('Command: %s', $cmdLine));
                $this->writeBgProcOutput($bgOutputFilename, PHP_EOL.PHP_EOL);
                $this->exec($cmdLine, $output, $bgOutputFilename);
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
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
        $cmd->setQuiet(TRUE);
        $cmd->execute($output);
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
                $cmdArgs[] = sprintf('"%s::%s"', $path, $archive->get('name'));
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                $this->writeBgProcOutput($bgOutputFilename, sprintf('Command: %s', $cmdLine));
                $this->writeBgProcOutput($bgOutputFilename, PHP_EOL.PHP_EOL);
                $this->exec($cmdLine, $output, $bgOutputFilename);
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
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
        $cmd->execute($output);
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
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
        $cmd->setQuiet(TRUE);
        $cmd->setBackground(TRUE);
        $cmd->execute($output);
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
        if ($repo->get('type') == 'local') {
            $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $repo->get('sharedfolderref')
            ], $context);
        } else {
            $path = $repo->get('uri');
        }
        $cmdArgs[] = sprintf('"%s::%s"', $path, $params['archive']);
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("BORG_PASSPHRASE", escapeshellarg($repo->get('passphrase')));
        $cmd->setQuiet(TRUE);
        $cmd->setBackground(TRUE);
        $cmd->execute($output);
    }

}
