# Windows Jenkins Slave client

This charm adds Windows host to a Jenkins master as a slave.

## Installing, configuring and testing

Assuming you already have a Juju environment already set up, download the charm onto a machine that can issue Juju commands, deploy the Jenkins charm and Windows Jenkins Slave charm and then add a relation between them.

Jenkins Slave for Windows charm must be downloaded locally on the juju machine under ~/charms/win2012r2/ (for Windows Server 2012 R2 deployment)

    juju deploy jenkins
    juju deploy --repository /path/to/charms/directory local:win2012r2/jenkins-slave-win

Create relations between jenkins and jenkins-slave-win:

    juju add-relation jenkins jenkins-slave-win


## Flow:

The charm only installs Java untill a relation is created with the jenkins master.

On relation-joined, the charm sets the fields on the relation requiered by the master to create a new node in Jenkins.

On relation-changed, the charm gets the requiered fields to download the slave.jar and the credentials to connect to the newly created node in Jenkins master.

This charm sets jenkins-slave as a service in Windows with automatic start.

On relation-departed, the jenkins-slave Windows service is uninstalled.

On relation-broken, all the files that the charm created (those necessary for creating the service and connecting to the master ) are deleted.

## config.yaml

Java-Url : the url for downloading the Java installer. Note that an offline installer is requiered.

Labels : the label that the slave node will have in Jenkins master. This is set automatically with the OS version of each slave node.

dorce-redownload : redownload the slave.jar file from the master that is used in connecting to jenkins master. There is little to no case for using this option. Only if there is an error in connecting to the master.