---
weight: 304
toc: true
title: Expose via Gateway API
menu:
    docs:
        parent: kube
lead: This guide will help you expose Prometheus, Alertmanager and Grafana using the Kubernetes Gateway API.
images: []
draft: false
description: This guide will help you expose Prometheus, Alertmanager and Grafana using the Kubernetes Gateway API.
---

The [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) is the successor to the Ingress API, providing a more expressive and extensible way to manage external access to services in a Kubernetes cluster. This guide explains how to use Gateway API resources to expose the Prometheus, Alertmanager and Grafana UIs included in the [kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) project.

> **Note:** The Gateway API is the recommended approach for exposing services. The [legacy Ingress-based guide](exposing-prometheus-alertmanager-grafana-ingress.md) is still available but Ingress (and notably the nginx-ingress-controller) is [deprecated](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/).

Note: before continuing, it is recommended to first get familiar with the [kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) stack by itself.

## Prerequisites

- A running Kubernetes cluster (v1.29+) with the [kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) stack deployed.
- A Gateway API implementation installed (e.g. [Envoy Gateway](https://gateway.envoyproxy.io/), [Istio](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/), [Cilium](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/), [Traefik](https://doc.traefik.io/traefik/providers/kubernetes-gateway/), [NGINX Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/), or others).
- The Gateway API CRDs installed in the cluster. Many implementations install these automatically, or you can install them manually:

```shell
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
```

## Gateway API concepts

The Gateway API uses three main resource types:

- **GatewayClass**: Defines a class of Gateways, typically provided by the infrastructure provider (similar to IngressClass).
- **Gateway**: Defines a load balancer that listens on specific ports and protocols.
- **HTTPRoute**: Defines routing rules that map hostnames and paths to backend services.

## Setting up Gateway API routes

The applications provide external links to themselves in alerts and various places. When a Gateway is used in front of the applications, these links need to be based on the external URLs. This can be configured for each application in jsonnet.

The following example creates a `Gateway` and individual `HTTPRoute` resources for Prometheus, Alertmanager, and Grafana:

```jsonnet
local httpRoute(name, namespace, gatewayName, hostnames, backendName, backendPort) = {
  apiVersion: 'gateway.networking.k8s.io/v1',
  kind: 'HTTPRoute',
  metadata: {
    name: name,
    namespace: namespace,
  },
  spec: {
    parentRefs: [{
      name: gatewayName,
      namespace: namespace,
    }],
    hostnames: hostnames,
    rules: [{
      matches: [{
        path: {
          type: 'PathPrefix',
          value: '/',
        },
      }],
      backendRefs: [{
        name: backendName,
        port: backendPort,
      }],
    }],
  },
};

local kp =
  (import 'kube-prometheus/main.libsonnet') +
  {
    values+:: {
      common+: {
        namespace: 'monitoring',
      },
      grafana+:: {
        config+: {
          sections+: {
            server+: {
              root_url: 'http://grafana.example.com/',
            },
          },
        },
      },
    },
    alertmanager+:: {
      alertmanager+: {
        spec+: {
          externalUrl: 'http://alertmanager.example.com',
        },
      },
    },
    prometheus+:: {
      prometheus+: {
        spec+: {
          externalUrl: 'http://prometheus.example.com',
        },
      },
    },
    gatewayAPI+:: {
      gateway: {
        apiVersion: 'gateway.networking.k8s.io/v1',
        kind: 'Gateway',
        metadata: {
          name: 'kube-prometheus',
          namespace: $.values.common.namespace,
        },
        spec: {
          gatewayClassName: 'example-gateway-class',
          listeners: [
            {
              name: 'http',
              protocol: 'HTTP',
              port: 80,
              allowedRoutes: {
                namespaces: {
                  from: 'Same',
                },
              },
            },
          ],
        },
      },
      'alertmanager-main': httpRoute(
        'alertmanager-main',
        $.values.common.namespace,
        'kube-prometheus',
        ['alertmanager.example.com'],
        'alertmanager-main',
        9093,
      ),
      grafana: httpRoute(
        'grafana',
        $.values.common.namespace,
        'kube-prometheus',
        ['grafana.example.com'],
        'grafana',
        3000,
      ),
      'prometheus-k8s': httpRoute(
        'prometheus-k8s',
        $.values.common.namespace,
        'kube-prometheus',
        ['prometheus.example.com'],
        'prometheus-k8s',
        9090,
      ),
    },
  };

{ [name + '-gateway-api']: kp.gatewayAPI[name] for name in std.objectFields(kp.gatewayAPI) }
```

> **Important:** Replace `example-gateway-class` with the `GatewayClass` name provided by your Gateway API implementation (e.g. `envoy`, `istio`, `cilium`, `traefik`).

In order to render the Gateway API objects similar to the other objects, add the following line to your output:

```jsonnet
{ ['00namespace-' + name]: kp.kubePrometheus[name] for name in std.objectFields(kp.kubePrometheus) } +
{ ['0prometheus-operator-' + name]: kp.prometheusOperator[name] for name in std.objectFields(kp.prometheusOperator) } +
{ ['node-exporter-' + name]: kp.nodeExporter[name] for name in std.objectFields(kp.nodeExporter) } +
{ ['kube-state-metrics-' + name]: kp.kubeStateMetrics[name] for name in std.objectFields(kp.kubeStateMetrics) } +
{ ['alertmanager-' + name]: kp.alertmanager[name] for name in std.objectFields(kp.alertmanager) } +
{ ['prometheus-' + name]: kp.prometheus[name] for name in std.objectFields(kp.prometheus) } +
{ ['grafana-' + name]: kp.grafana[name] for name in std.objectFields(kp.grafana) } +
{ ['gateway-api-' + name]: kp.gatewayAPI[name] for name in std.objectFields(kp.gatewayAPI) }
```

Note, that in comparison only the last line was added, the rest is identical to the original.

See [gateway-api.jsonnet](https://github.com/prometheus-operator/kube-prometheus/tree/main/examples/gateway-api.jsonnet) for the full example implementation.

## TLS termination

To enable TLS termination at the Gateway, add an HTTPS listener that references a Kubernetes Secret containing the TLS certificate:

```jsonnet
gateway: {
  apiVersion: 'gateway.networking.k8s.io/v1',
  kind: 'Gateway',
  metadata: {
    name: 'kube-prometheus',
    namespace: $.values.common.namespace,
  },
  spec: {
    gatewayClassName: 'example-gateway-class',
    listeners: [
      {
        name: 'https',
        protocol: 'HTTPS',
        port: 443,
        tls: {
          mode: 'Terminate',
          certificateRefs: [{
            name: 'kube-prometheus-tls',
          }],
        },
        allowedRoutes: {
          namespaces: {
            from: 'Same',
          },
        },
      },
    ],
  },
},
```

## Authentication

Unlike the Ingress API where authentication could be configured via controller-specific annotations (e.g. nginx basic auth annotations), the Gateway API does not include a built-in authentication mechanism. Authentication should be handled through one of the following approaches:

- **Implementation-specific policies**: Many Gateway API implementations offer their own authentication policy resources (e.g. Envoy Gateway's `SecurityPolicy`, Istio's `AuthorizationPolicy`).
- **External authentication proxy**: Deploy an authentication proxy like [OAuth2 Proxy](https://oauth2-proxy.github.io/oauth2-proxy/) or [Pomerium](https://www.pomerium.com/) in front of the services.
- **Application-level authentication**: Grafana has built-in authentication support. Prometheus and Alertmanager can be placed behind an authenticating reverse proxy.

Refer to your Gateway API implementation's documentation for specific authentication configuration options.

## Updating NetworkPolicies

NetworkPolicies restricting access to the components are added by default. These can either be removed as in
[networkpolicies-disabled.jsonnet](https://github.com/prometheus-operator/kube-prometheus/tree/main/examples/networkpolicies-disabled.jsonnet) or modified to
allow traffic from the Gateway's namespace/pods.

This is an example for alertmanager, but the same can be applied to prometheus and grafana. Adjust the label selector to match your Gateway API implementation's data plane pods:

```jsonnet
{
  alertmanager+:: {
    networkPolicy+: {
      spec+: {
        ingress: [
          super.ingress[0] + {
            from+: [
              {
                namespaceSelector: {
                  matchLabels: {
                    'kubernetes.io/metadata.name': 'gateway-system',
                  },
                },
              },
            ],
          },
        ] + super.ingress[1:],
      },
    },
  },
}
```

> **Note:** The namespace label and name will vary depending on your Gateway API implementation. Check where your implementation deploys its data plane proxies and adjust the `namespaceSelector` accordingly.
