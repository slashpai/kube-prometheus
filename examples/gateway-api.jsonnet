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
