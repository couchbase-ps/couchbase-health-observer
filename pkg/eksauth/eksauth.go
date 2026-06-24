// Package eksauth builds a Kubernetes client for an EKS cluster from AWS credentials. The
// bearer token is produced by the reference aws-iam-authenticator generator (the same
// thing `aws eks get-token` uses), so the switch Lambda (which runs outside the cluster)
// authenticates to the EKS API with its IAM role, mapped to Kubernetes RBAC via an EKS
// access entry. The cluster endpoint and CA come from the AWS SDK v2 EKS API.
package eksauth

import (
	"context"
	"encoding/base64"
	"fmt"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/eks"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/aws-iam-authenticator/pkg/token"
)

// ClusterToken returns the EKS bearer token for the named cluster using ambient AWS
// credentials.
func ClusterToken(ctx context.Context, clusterName string) (string, error) {
	gen, err := token.NewGenerator(false, false)
	if err != nil {
		return "", fmt.Errorf("token generator: %w", err)
	}
	tk, err := gen.GetWithOptions(ctx, &token.GetTokenOptions{ClusterID: clusterName})
	if err != nil {
		return "", fmt.Errorf("get token: %w", err)
	}
	return tk.Token, nil
}

// Clientset builds a Kubernetes client for the named EKS cluster using the ambient AWS
// credentials (the Lambda execution role).
func Clientset(ctx context.Context, clusterName string) (kubernetes.Interface, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}

	desc, err := eks.NewFromConfig(cfg).DescribeCluster(ctx, &eks.DescribeClusterInput{Name: &clusterName})
	if err != nil {
		return nil, fmt.Errorf("describe cluster %s: %w", clusterName, err)
	}
	ca, err := base64.StdEncoding.DecodeString(*desc.Cluster.CertificateAuthority.Data)
	if err != nil {
		return nil, fmt.Errorf("decode cluster CA: %w", err)
	}

	tk, err := ClusterToken(ctx, clusterName)
	if err != nil {
		return nil, err
	}

	return kubernetes.NewForConfig(&rest.Config{
		Host:        *desc.Cluster.Endpoint,
		BearerToken: tk,
		TLSClientConfig: rest.TLSClientConfig{
			CAData: ca,
		},
	})
}
