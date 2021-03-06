#!/bin/bash

mkdir -p logs

export SOURCEPATH=$(cd $(dirname $BASH_SOURCE); echo $PWD)
source $SOURCEPATH/util

# Job specific variables
TEUTH_NAME=${TEUTH_NAME:-"ci"}
TEUTH_BRANCH=${TEUTH_BRANCH:-"master"}

CEPH_BRANCH=${CEPH_BRANCH:-"ses6"}
SUITE_BRANCH=${SUITE_BRANCH:-"ses6"}

#PRTGT_BRANCH=${ghprbTargetBranch:-"ses5"}
#if [[ "$PRTGT_BRANCH" == "master" ]] ; then
#    CEPH_BRANCH="ses6"
#    SUITE_BRANCH="ses6"
#else
#    CEPH_BRANCH="${PRTGT_BRANCH,,}"
#    SUITE_BRANCH="${PRTGT_BRANCH,,}"
#fi


TEUTH_PATH=${TEUH_PATH:-"$HOME/teuthology"}
TEUTH_SUITE=${SUITE:-"deepsea:basic:health-ok"}
TEUTH_EXTRA=${TEUTH_FILTER:-"--filter sle"}

CEPH_REPO=${CEPH_REPO:-"http://github.com/SUSE/ceph"}
TEUTH_REPO=${TEUTH_REPO:-"http://github.com/SUSE/teuthology"}
SUITE_REPO=${SUITE_REPO:-"http://github.com/SUSE/ceph"}

# Jenkins specific variables
JOB_NAME=${JOB_NAME:-"deepsea-teuthology"}
BUILD_ID=${BUILD_ID:-"0"}
#OVH_CONF=${OVH_CONF:-"ovh.net"}
PULL_ID=${ghprbPullId:-"0"}

TEUTH_LOG=logs/teuth-deepsea-pr$PULL_ID-b$BUILD_ID.log

echo DeepSea repo: $DEEPSEAREPOURL


# include OVH_CONF
# source $OVH_CONF

# include teuthology
echo Home directory: $HOME
source $TEUTH_PATH/v/bin/activate

function print_artifacts() {
    local yaml=$1
    python -c "import sys, yaml ; ars = yaml.load(sys.stdin)['artifacts']
print(' '.join(ars.keys()))" < $yaml
}

function teuth_test_repos() {
    local yaml=${1}
    shift
    local artifacts=${@:-"$(print_artifacts $yaml)"}
    for i in $artifacts ; do
        python -c "import sys, yaml
ars=yaml.load(sys.stdin)['artifacts']
print('--test-repo %s:%s' % ('$i', ars['$i']['url']))" \
< $yaml
    done
}

test -f artifacts-$CEPH_BRANCH.yaml && {
    echo Found artifact file artifacts-$CEPH_BRANCH.yaml
    TEST_REPO=$(teuth_test_repos artifacts-$CEPH_BRANCH.yaml)
} || {
    if [[ "x$ARTIFACTS" != "x" ]] ; then
        echo "$ARTIFACTS" > artifacts.yaml
        TEST_REPO=$(teuth_test_repos artifacts.yaml)
    fi
}
if [[ "x$DEEPSEA_REPO" != "x" ]] ; then
    TEST_REPO="$TEST_REPO --test-repo deepsea!1:$DEEPSEA_REPO"
fi


cat <<EOF > $PWD/deepsea-overrides.yaml
overrides:
    install:
        ceph:
            packages:
                deb: []
                rpm: []
    deepsea:
        install: package
        repo: ''

EOF

teuthology-openstack -v \
    --name ${TEUTH_NAME} \
    --key-filename $SECRET_FILE \
    --teuthology-git-url ${TEUTH_REPO} \
    --teuthology-branch ${TEUTH_BRANCH} \
    --suite-repo ${SUITE_REPO} \
    --suite-branch ${SUITE_BRANCH} \
    --ceph-repo ${CEPH_REPO} \
    --ceph ${CEPH_BRANCH} \
    --suite ${TEUTH_SUITE} \
    $TEST_REPO \
    $TEUTH_EXTRA \
    $PWD/deepsea-overrides.yaml \
    --wait 2>&1 | tee $TEUTH_LOG

#    --test-repo ses5:http://storage-ci.suse.de/artifacts/13efbdd685728106cb7ca9ec29a967236c402aafbd23efdb98e998df8474f98a/SUSE-Enterprise-Storage-5-POOL-x86_64-Build0609 \
#    --test-repo ses5-internal:http://storage-ci.suse.de/artifacts/941df0216e4adc9eeed1d607bc20bce6dc854255ac346c79301ed2a8de787e98/SUSE-Enterprise-Storage-5-POOL-Internal-x86_64-Build0609 \
    
    # verify if RC is accurate

fails=$(grep -sc 'teuthology.suite:fail' $TEUTH_LOG)
deads=$(grep -sc 'teuthology.suite:dead' $TEUTH_LOG)
passed=$(grep -sc 'teuthology.suite:pass' $TEUTH_LOG)
total=$(grep -sc 'Job scheduled with name' $TEUTH_LOG)
alljobs=$(grep 'Job scheduled with name' $TEUTH_LOG | \
          perl -n -e'/ID ([0-9]+)/ && CORE::say $1')
jobname=$(grep 'Job scheduled with name' $TEUTH_LOG | head -1 | \
          perl -n -e'/name ([^ ]+)/ && CORE::say $1')
teuth=$(grep -m1 'ssh access' $TEUTH_LOG | \
        perl -n -e'/ubuntu@([^ ]+) #/ && CORE::say $1')

runname=$jobname
runurl=http://$teuth:8081/$runname
echo "Run summary: suite=$TEUTH_SUITE|name=$runname|url=$runurl"

function make_teuthology_junit() {
    local logdir=$1
    local junit=${2:-"junit-report.xml"}
    local suite=${3:-"run"}
    local class="${suite//[:\/]/\:}"
    cat > $junit << END
<?xml version="1.0" ?>
<testsuite name="$suite">
END
        for i in $(ls $logdir) ; do
            local summary_yaml=$logdir/$i/summary.yaml
            local info_yaml=$logdir/$i/info.yaml
            local name=$(
                python -c "import sys, yaml ; print(yaml.load(sys.stdin)['description'])" < $info_yaml
            )
            name=${name/"$class"\//}
            local dura=$(
                python -c "import sys, yaml ; print(yaml.load(sys.stdin)['duration'])" < $summary_yaml || echo "0"
            )
            local tlog=$logdir/teuthology-$i.log
            cp $logdir/$i/teuthology.log $tlog
            cat >> $junit << END
  <testcase classname="teuthology.$class" name="$name" time="$dura">
    <system-out>$(make_brief_deepsea_report $logdir/$i/teuthology.log | to_xml)

	[[ATTACHMENT|$tlog]]

    </system-out>
END
            grep "^success:" $summary_yaml | grep -q "true" || {
                local reason=$(
                    python -c "import sys, yaml ; from xml.dom.minidom import Text ; \
                        t = Text() ; t.data = yaml.load(sys.stdin)['failure_reason'] ; \
                        print(t.toxml())" < $summary_yaml
                )
                cat >> $junit << END
    <failure>$reason

$(cat $logdir/$i/teuthology.log | extract_stack_trace | to_xml)
    </failure>
END
            }
            cat >> $junit << END
  </testcase>
END
        done
        cat >> $junit << END
</testsuite>
END
}
function make_message() {
    local logdir=$1
    local message=$2
    for i in $(ls $logdir) ; do
        local summary_yaml=$logdir/$i/summary.yaml
        local info_yaml=$logdir/$i/info.yaml
        local name=$(
            python -c "import sys, yaml ; print(yaml.load(sys.stdin)['description'])" < $info_yaml
        )
        name=${name/"$class"\//}
        local dura=$(
            python -c "import sys, yaml ; print(yaml.load(sys.stdin)['duration'])" < $summary_yaml || echo "0"
        )
        local tlog=$logdir/teuthology-$i.log
        cp $logdir/$i/teuthology.log $tlog
        grep "^success:" $summary_yaml | grep -q "true" || {
            local reason=$(
                python -c "import sys, yaml ; from xml.dom.minidom import Text ; \
                    t = Text() ; t.data = yaml.load(sys.stdin)['failure_reason'] ; \
                    print(t.toxml())" < $summary_yaml
            )
            cat >> $junit << END
$(make_brief_deepsea_report $logdir/$i/teuthology.log | to_xml)
END
        }
    done
}

function make_teuthology_html() {
    local logdir=$1
    local report=${2:-"teuthology-report.html"}
    local suite=${3:-"teuthology"}
    local class="teuthology.${suite//[:\/]/\.}"
    cat > $report << END
<html>
<body>
END
    [[ "$ghprbPullLink" == "" ]] || {
        cat > $report << END
<p>$ghprbPullLink</p><br/>
END
    }
    cat > $report << END
Results for run <a href="$runurl">$runname</a>
<table>
<thead>
<tr><th>NAME</th><th>TIME</th><th>STATUS</th></tr>
</thead>
END
        for i in $(ls $logdir) ; do
            local summary_yaml=$logdir/$i/summary.yaml
            local info_yaml=$logdir/$i/info.yaml
            local name=$(
                python -c "import sys, yaml ; print(yaml.load(sys.stdin)['description'])" < $info_yaml
            )
            local dura=$(
                python -c "import sys, yaml ; print(yaml.load(sys.stdin)['duration'])" < $summary_yaml || echo "0"
            )
            local tlog="../$logdir/$i/teuthology.log"
            cat >> $report << END
  <tr>
    <td>$name</td>
    <td>$dura</td>
END
            grep "^success:" $summary_yaml | grep -q "true" && {
                cat >> $report << END
    <td><a href="$tlog" style="text-decoration: none; color: green">passed</a></td>
END
            } || {
                local reason=$(
                    python -c "import sys, yaml ; print(yaml.load(sys.stdin)['failure_reason'])" < $summary_yaml
                )
                cat >> $report << END
    <td><a href="$tlog" style="text-decoration: none; color: red" title="$reason">failed</a></td>
END
            }
            cat >> $report << END
  </tr>
END
        done
        cat >> $report << END
</table>
</body>
</html>
END
}

make_github_report() {
    local logdir=$1
    local report=${2:-"report.txt"}
    cat > $report << END
Results for [teuthology ${TEUTH_SUITE} suite run]($runurl)
Run name: $runname
---

END
        for i in $(ls $logdir) ; do
            local summary_yaml=$logdir/$i/summary.yaml
            local info_yaml=$logdir/$i/info.yaml
            local name=$(
                python -c "import sys, yaml ; print(yaml.load(sys.stdin)['description'])" < $info_yaml
            )
            local dura=$(
                python -c "import sys, yaml ; print(yaml.load(sys.stdin)['duration'])" < $summary_yaml || echo "0"
            )
            (grep "^success:" $summary_yaml | grep -q "true") && {
                cat >> $report << END
- _PASSED_ - $name :+1:
END
            } || {
                local reason=$(
                    python -c "import sys, yaml ; print(yaml.load(sys.stdin)['failure_reason'])" < $summary_yaml
                )
                cat >> $report << END
- _**FAILED**_ - $name :hankey:
END
                if [[ "$reason" != "" ]] ; then
                cat >> $report << END
\`\`\`
$reason
\`\`\`
END
                fi
            }
        done
}

if [[ "x$jobname" == "x" ]] ; then
    echo "ERROR: Can't determine jobname"
    cat > logs/report.txt << EOF
Can't determine teuthology job name
EOF
    exit 3
else
    mkdir -p logs/$jobname
    scp -r -i $SECRET_FILE -o StrictHostKeyChecking=no ubuntu@$teuth:/usr/share/nginx/html/$jobname/* logs/$jobname || true
    HTML_REPORT=teuthology-${TEUTH_SUITE//\//\:}
    make_github_report logs/$jobname logs/report.txt
    make_teuthology_html logs/$jobname logs/$HTML_REPORT
    (cd logs ; ln -s $HTML_REPORT teuthology-report.html)
    make_teuthology_junit logs/$jobname logs/junit-report.xml $TEUTH_SUITE
fi

echo PASS: $passed
echo FAIL: $fails
echo DEAD: $deads
echo TOTAL: $total
echo JOBS: $alljobs

[ $((fails + deads)) -eq 0 ] || {
    echo "ERROR: There are failed jobs"
    exit 1
}
[ $((fails + deads + passed)) -gt 0 ] || {
    echo "ERROR: Neither jobs passed, nor failed"
    exit 2
}

