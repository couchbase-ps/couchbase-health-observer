// Package eksauth builds a Kubernetes client for an EKS cluster from AWS credentials,
// the way `aws eks get-token` does: a presigned STS GetCallerIdentity request, carrying
// the cluster name in a signed header, encoded as the cluster bearer token. This lets the
// switch Lambda (which runs outside the cluster) authenticate to the EKS API using its
// IAM role, mapped to Kubernetes RBAC via an EKS access entry.
package eksauth

import (
	"context"
	"encoding/base64"
	"fmt"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/eks"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	smithyhttp "github.com/aws/smithy-go/transport/http"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	tokenPrefix   = "k8s-aws-v1."
	clusterHeader = "x-k8s-aws-id"
)

// encodeToken wraps a presigned STS URL into the EKS bearer-token format.
func encodeToken(presignedURL string) string {
	return tokenPrefix + base64.RawURLEncoding.EncodeToString([]byte(presignedURL))
}

// token presigns an STS GetCallerIdentity request with the cluster name in the signed
// x-k8s-aws-id header and returns the EKS bearer token.
func token(ctx context.Context, stsClient *sts.Client, clusterName string) (string, error) {
	presigner := sts.NewPresignClient(stsClient)
	out, err := presigner.PresignGetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}, func(po *sts.PresignOptions) {
		po.ClientOptions = append(po.ClientOptions, func(o *sts.Options) {
			o.APIOptions = append(o.APIOptions, smithyhttp.SetHeaderValue(clusterHeader, clusterName))
		})
	})
	if err != nil {
		return "", fmt.Errorf("presign sts: %w", err)
	}
	return encodeToken(out.URL), nil
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

	tok, err := token(ctx, sts.NewFromConfig(cfg), clusterName)
	if err != nil {
		return nil, err
	}

	return kubernetes.NewForConfig(&rest.Config{
		Host:        *desc.Cluster.Endpoint,
		BearerToken: tok,
		TLSClientConfig: rest.TLSClientConfig{
			CAData: ca,
		},
	})
}
