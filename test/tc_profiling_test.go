/*
Copyright 2021 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package e2e_test

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"strings"
	"time"

	v1 "k8s.io/api/core/v1"
	spoutil "sigs.k8s.io/security-profiles-operator/internal/pkg/util"
)

func (e *e2e) testCaseProfilingChange([]string) {
	e.logf("Change profiling in spod")
	e.kubectlOperatorNS("patch", "spod", "spod", "-p", `{"spec":{"enableProfiling": true}}`, "--type=merge")
	time.Sleep(defaultWaitTime)

	e.waitInOperatorNSFor("condition=ready", "spod", "spod")
	e.kubectlOperatorNS("rollout", "status", "ds", "spod", "--timeout", defaultBpfRecorderOpTimeout)

	logs := e.kubectlOperatorNS(
		"logs",
		"ds/spod",
		"security-profiles-operator",
	)

	e.Contains(logs, "Profiling support enabled: true")
}

func (e *e2e) testCaseProfilingHTTP([]string) {
	e.selinuxOnlyTestCase()
	e.logf("Test profiling HTTP version")
	e.logf("enable selinux in the spod object, this is needed to test the profiling endpoint")
	e.kubectlOperatorNS("patch", "spod", "spod", "-p", `{"spec":{"enableSelinux": true}}`, "--type=merge")
	time.Sleep(defaultWaitTime)
	e.waitInOperatorNSFor("condition=ready", "spod", "spod")
	e.logf("assert selinux is enabled in the spod DS")
	selinuxEnabledInSPODDS := e.kubectlOperatorNS("get", "ds", "spod", "-o", "yaml")
	e.Contains(selinuxEnabledInSPODDS, "--with-selinux=true")

	e.logf("Enable spod profiling to test endpoint HTTP version")
	e.kubectlOperatorNS("patch", "spod", "spod", "-p", `{"spec":{"enableProfiling": true}}`, "--type=merge")
	time.Sleep(defaultWaitTime)

	e.waitInOperatorNSFor("condition=ready", "spod", "spod")

	output := e.getProfilingHTTPVersion()
	e.Contains(output, "1.1\n")

	e.logf("Disable selinux from SPOD")
	e.kubectlOperatorNS("patch", "spod", "spod", "-p", `{"spec":{"enableSelinux": false}}`, "--type=merge")

	time.Sleep(defaultWaitTime)
	e.waitInOperatorNSFor("condition=ready", "spod", "spod")
}

func (e *e2e) getProfilingEndpoint() string {
	spodListOutput := e.kubectlOperatorNS("get", "pod", "-l", "app=spod", "-o", "json")
	// printout the spod list output
	e.logf("spod list output: %s", spodListOutput)
	var spodList v1.PodList
	if err := json.Unmarshal([]byte(spodListOutput), &spodList); err != nil {
		e.Failf("unable to unmarshal spod list", "error: %s", err)
	}
	if len(spodList.Items) == 0 {
		e.Fail("no spod found")
	}
	spod := spodList.Items[0]
	// find the security-profiles-operator container for SPO_PROFILING_PORT env var
	var podPort string
	for _, container := range spod.Spec.Containers {
		if container.Name == "security-profiles-operator" {
			for _, env := range container.Env {
				if env.Name == "SPO_PROFILING_PORT" {
					podPort = env.Value
				}
			}
		}
	}
	if podPort == "" {
		e.Fail("no profiling port found")
	}
	// find the pod IP
	podIP := spod.Status.PodIP
	if podIP == "" {
		e.Fail("no pod IP found")
	}
	return "http://" + podIP + ":" + podPort + "/debug/pprof/heap"
}

// This funcion is inspired by e2e.runAndRetryPodCMD().
func (e *e2e) getProfilingHTTPVersion() string {
	r := rand.New(rand.NewSource(time.Now().UnixNano())) // #nosec
	letters := []rune("abcdefghijklmnopqrstuvwxyz")
	b := make([]rune, 10)
	for i := range b {
		b[i] = letters[r.Intn(len(letters))]
	}
	// Sometimes the endpoint does not output anything in CI. We fix
	// that by retrying the endpoint several times.
	var output string
	if err := spoutil.Retry(func() error {
		profilingEndpoint := e.getProfilingEndpoint()
		profilingCurlCMD := curlHTTPVerCMD + profilingEndpoint
		output = e.kubectlRunOperatorNS("pod-"+string(b), "--", "bash", "-c", profilingCurlCMD)
		if len(strings.Split(output, "\n")) > 1 {
			return nil
		}
		output = ""
		return fmt.Errorf("no output from profiling curl command")
	}, func(err error) bool {
		e.logf("retry on error: %s", err)
		return true
	}); err != nil {
		e.Failf("unable to get profiling endpoint http version", "error: %s", err)
	}
	return output
}
